package com.botts.impl.security;

import java.security.GeneralSecurityException;
import java.security.SecureRandom;
import java.security.spec.KeySpec;
import java.util.Arrays;
import java.util.Base64;

import javax.crypto.SecretKeyFactory;
import javax.crypto.spec.PBEKeySpec;

import org.eclipse.jetty.util.security.Credential;
import org.eclipse.jetty.util.security.Password;

/**
 * Represents a password that has been hashed using PBKDF2 and the SHA1 HMAC.
 */
public class PBKDF2Credential extends Credential {
	private static final long serialVersionUID = 1L;

	/**
	 * Log base 2 of the number of hashing iterations to use, by default. This can be used to increase the difficulty
	 * of brute-force attacks by increasing the calculations necessary for each password check.
	 */
	public static final int DEFAULT_STRENGTH = 16;
	
	/**
	 * How many bits are calculated when the password is hashed. This is fixed by the choice of algorithm.
	 */
	public static final int HASH_BITS = 128;
	
	/**
	 * How many random bytes are generated for salt. This is also fixed by the choice of algorithm.
	 */
	public static final int SALT_LENGTH = 16;
	
	/**
	 * What character is used to separate the components of the encoded password when it is stringified for saving in a
	 * config file or database.
	 */
	public static final char SEPARATOR = ':';
	
	/**
	 * Secret key algorithm to use. This must be known to the JSSE implementation at runtime.
	 */
	public static final String ALGORITHM = "PBKDF2WithHmacSHA1";
	
	/**
	 * Prefix to use when the password is stringified. Lets Jetty identify this credential provider.
	 */
	public static final String PREFIX = ALGORITHM + SEPARATOR;

	private final String stringifiedCredential;
	private final byte[] salt;
	private final byte[] hash;
	private final int strength;
	
	private PBKDF2Credential(String stringifiedCredential, byte[] salt, byte[] hash, int strength) {
		this.stringifiedCredential = stringifiedCredential;
		this.salt = salt;
		this.hash = hash;
		this.strength = strength;
	}
	
	public static PBKDF2Credential fromEncoded(String stringifiedCredential) {
		String strengthSaltHashString = stringifiedCredential.substring(PREFIX.length());
		int separatorIndex;
		
		separatorIndex = strengthSaltHashString.indexOf(SEPARATOR);
		String strengthString = strengthSaltHashString.substring(0, separatorIndex);
		String saltHashString = strengthSaltHashString.substring(separatorIndex + 1);
		separatorIndex = saltHashString.indexOf(SEPARATOR);
		String saltString = saltHashString.substring(0, separatorIndex);
		String hashString = saltHashString.substring(separatorIndex + 1);
		
		Base64.Decoder base64Decoder = Base64.getDecoder();
		byte[] salt = base64Decoder.decode(saltString);
		byte[] hash = base64Decoder.decode(hashString);
		int strength = Integer.parseInt(strengthString);
		return new PBKDF2Credential(stringifiedCredential, salt, hash, strength);
	}
	
	public static PBKDF2Credential fromPassword(String password, int strength) throws GeneralSecurityException {
		SecureRandom random = new SecureRandom();
		byte[] salt = new byte[16];
		random.nextBytes(salt);

		KeySpec keySpec = new PBEKeySpec(password.toCharArray(), salt, getIterationsFromStrength(strength), HASH_BITS);
		SecretKeyFactory secretKeyFactory = SecretKeyFactory.getInstance(ALGORITHM);
		
		byte[] hash = secretKeyFactory.generateSecret(keySpec).getEncoded();

		Base64.Encoder base64Encoder = Base64.getEncoder();
		
		String stringifiedCredential = PREFIX + strength + SEPARATOR + base64Encoder.encodeToString(salt) +
				SEPARATOR + base64Encoder.encodeToString(hash);

		return new PBKDF2Credential(stringifiedCredential, salt, hash, strength);
	}
	
	private boolean check(String password) {
		try {
			KeySpec keySpec = new PBEKeySpec(password.toCharArray(), salt, getIterationsFromStrength(strength), HASH_BITS);
			SecretKeyFactory secretKeyFactory = SecretKeyFactory.getInstance(ALGORITHM);
			byte[] testHash = secretKeyFactory.generateSecret(keySpec).getEncoded();
			return Arrays.equals(hash, testHash);
		} catch (GeneralSecurityException gse) {
			throw new RuntimeException("Unable to check password", gse);
		}
	}

	private static int getIterationsFromStrength(int strength) {
		return 1 << strength;
	}

	@Override
	public boolean check(Object credentials) {
		if (credentials == null) {
			return false;
		}
		if (credentials instanceof String) {
			String password = (String) credentials;
			return check(password);
		}
		if (credentials instanceof Password) {
			String password = ((Password) credentials).toString();
			return check(password);
		}
		if (credentials instanceof char[]) {
			String password = new String((char[]) credentials);
			return check(password);
		}
		// We don't know how to validate against any other types of credential
		// input, so we return false in those cases.
		return false;
	}

	@Override
	public String toString() {
		return stringifiedCredential;
	}
}
