package com.botts.impl.security;

import java.io.BufferedReader;
import java.io.IOException;
import java.io.InputStreamReader;
import java.security.GeneralSecurityException;

import org.eclipse.jetty.util.security.Credential;
import org.eclipse.jetty.util.security.CredentialProvider;

public class PBKDF2CredentialProvider implements CredentialProvider {
	private int strength = PBKDF2Credential.DEFAULT_STRENGTH;

	public PBKDF2CredentialProvider() {
	}

	public int getStrength() {
		return strength;
	}

	public void setStrength(int strength) {
		this.strength = strength;
	}

	@Override
	public Credential getCredential(String credential) {
		return PBKDF2Credential.fromEncoded(credential);
	}

	@Override
	public String getPrefix() {
		return PBKDF2Credential.PREFIX;
	}

	public static String encode(String password) {
		return PBKDF2Credential.fromPassword(password).toString();
	}

	public static void main(String[] args) throws IOException, GeneralSecurityException {
		String password;
		int strength = PBKDF2Credential.DEFAULT_STRENGTH;
		if (args.length > 0) {
			strength = Integer.parseInt(args[0]);
		}
		if (args.length > 1) {
			password = args[1];
		} else {
			try (BufferedReader bufferedReader = new BufferedReader(new InputStreamReader(System.in))) {
				password = bufferedReader.readLine();
			}
		}
		PBKDF2Credential credential = PBKDF2Credential.fromPassword(password, strength);
		System.out.println(credential.toString());
	}
}
