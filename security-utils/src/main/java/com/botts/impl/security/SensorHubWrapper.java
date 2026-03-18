package com.botts.impl.security;

import java.io.BufferedReader;
import java.io.File;
import java.io.FileInputStream;
import java.io.IOException;
import java.io.InputStreamReader;
import java.nio.charset.StandardCharsets;

import org.sensorhub.impl.SensorHub;

/**
 * Simple wrapper around org.sensorhub.impl.SensorHub that sets TLS-related system properties programmatically so that
 * passwords are not shown in the process's command line (in "-Djavax.net.ssl.keyStorePassword" for example).
 */
public class SensorHubWrapper {
	/**
	 * Name of the environment variable that specifies the path to a keystore that will be used for the
	 * "javax.net.ssl.keyStore" system property.
	 */
	public static final String KEYSTORE = "KEYSTORE";

	/**
	 * Name of the environment variable that specifies the type (e.g. "jks" or "pkcs12") of the file named by the
	 * KEYSTORE environment variable. This is used for the "javax.net.ssl.keyStoreType" system property.
	 */
	public static final String KEYSTORE_TYPE = "KEYSTORE_TYPE";

	/**
	 * Name of the environment variable that specifies the password for the keystore. Users should prefer to use the
	 * KEYSTORE_PASSWORD_FILE environment variable instead, though.
	 */
	public static final String KEYSTORE_PASSWORD = "KEYSTORE_PASSWORD";

	/**
	 * Name of the environment variable that specifies the path to a certificate store that will be used for the
	 * "javax.net.ssl.trustStore" system property.
	 */
	public static final String TRUSTSTORE = "TRUSTSTORE";

	/**
	 * Name of the environment variable that specifies the type (e.g. "jks" or "pkcs12") of the file named by the
	 * TRUSTSTORE environment variable. This is used for the "javax.net.ssl.trustStoreType" system property.
	 */
	public static final String TRUSTSTORE_TYPE = "TRUSTSTORE_TYPE";

	/**
	 * Name of the environment variable that specifies the password for the trsut store. Users should prefer to use the
	 * TRUSTSTORE_PASSWORD_FILE environment variable instead.
	 */
	public static final String TRUSTSTORE_PASSWORD = "TRUSTSTORE_PASSWORD";

	/**
	 * Suffix to add to the names of the password-related environment variables that will instruct us to get it from
	 * the named file, rather than from the value of the environment variable itself.
	 */
	public static final String FILE_SUFFIX = "_FILE";

	/**
	 * Name of the environment variable that, if set to a non-empty value, will cause this class to emit some
	 * information about where it loaded certificates from.
	 */
	public static final String SHOW_CMD = "SHOW_CMD";

	public static void main(String[] args) throws IOException {
		String showCmdEnv = System.getenv(SHOW_CMD);
		boolean debug = nonBlank(showCmdEnv);

		// We're assuming that the startup script will have set values for these things so that we don't have to check
		// for empty/non-set values.
		String keyStoreEnv = System.getenv(KEYSTORE);
		String keyStoreTypeEnv = System.getenv(KEYSTORE_TYPE);

		PasswordValue keyStorePassword;
		File appSecrets = new File(".app_secrets");
		if (appSecrets.exists()) {
			String val = firstLineOfFile(appSecrets.getAbsolutePath());
			keyStorePassword = new PasswordValue(val, "KEYSTORE_PASSWORD_FILE", appSecrets.getAbsolutePath(), PasswordSpecifier.FILE_ENVIRONMENT_VARIABLE);
		} else {
			keyStorePassword = getPasswordValue(KEYSTORE_PASSWORD, "changeit");
		}

		System.setProperty("javax.net.ssl.keyStore", keyStoreEnv);
		System.setProperty("javax.net.ssl.keyStoreType", keyStoreTypeEnv);
		System.setProperty("javax.net.ssl.keyStorePassword", keyStorePassword.getValue());

		String trustStoreEnv = System.getenv(TRUSTSTORE);
		String trustStoreTypeEnv = System.getenv(TRUSTSTORE_TYPE);
		PasswordValue trustStorePassword = getPasswordValue(TRUSTSTORE_PASSWORD, "changeit");

		System.setProperty("javax.net.ssl.trustStore", trustStoreEnv);
		System.setProperty("javax.net.ssl.trustStoreType", trustStoreTypeEnv);
		System.setProperty("javax.net.ssl.trustStorePassword", trustStorePassword.getValue());

		if (debug) {
			System.out.println("Key store:            " + keyStoreEnv);
			System.out.println("Key store type:       " + keyStoreTypeEnv);
			System.out.println("Key store password:   " + keyStorePassword.getDescription());

			System.out.println("Trust store:          " + trustStoreEnv);
			System.out.println("Trust store type:     " + trustStoreTypeEnv);
			System.out.println("Trust store password: " + trustStorePassword.getDescription());
		}

		SensorHub.main(args);
	}

	/**
	 * Utility method for getting passwords from environment variables.
	 *
	 * We're assuming that passwords will be provided in one of two ways: (1) by specifying a "secret file" in an
	 * environment variable named "XXX_FILE", whose content is the password, or (2) by specifying the password
	 * directly in an environment variable named just "XXX" (without the "_FILE" prefix).
	 *
	 * This method here checks the "_FILE" version first, and if it's present, returns the content of the file as a
	 * String. Otherwise it will look for plain "XXX" and return the value of that environment variable, if present.
	 * And if neither is present, will return the default value given as the second parameter.
	 */
	private static PasswordValue getPasswordValue(String envVarName, String defaultValue) throws IOException {
		String fileEnvVarName = envVarName + FILE_SUFFIX;

		String filename = System.getenv(fileEnvVarName);
		if (nonBlank(filename)) {
			String value = firstLineOfFile(filename);
			return new PasswordValue(value, fileEnvVarName, filename, PasswordSpecifier.FILE_ENVIRONMENT_VARIABLE);
		} else {
			String value = System.getenv(envVarName);
			if (nonBlank(value)) {
				return new PasswordValue(value, envVarName, null, PasswordSpecifier.ENVIRONMENT_VARIABLE);
			} else {
				return new PasswordValue(value, null, null, PasswordSpecifier.DEFAULT_VALUE);
			}
		}
	}

	/**
	 * Reads the first line of a file and returns it as a String. Assumes UTF-8 encoding in the file. Does not include
	 * the line terminator in the return value.
	 */
	private static String firstLineOfFile(String path) throws IOException {
		try (FileInputStream fileIn = new FileInputStream(path);
				InputStreamReader fileReader = new InputStreamReader(fileIn, StandardCharsets.UTF_8);
				BufferedReader bufferedReader = new BufferedReader(fileReader)) {
			return bufferedReader.readLine();
		}
	}

	/**
	 * Returns true if the given string is non-null and has length greater than zero. Returns false otherwise.
	 */
	private static boolean nonBlank(String s) {
		return (s != null) && (s.length() > 0);
	}

	public enum PasswordSpecifier {
		ENVIRONMENT_VARIABLE,
		FILE_ENVIRONMENT_VARIABLE,
		DEFAULT_VALUE
	}

	public static class PasswordValue {
		private final String value;
		private final String envVarName;
		private final String filename;
		private final PasswordSpecifier how;

		public PasswordValue(String value, String envVarName, String filename, PasswordSpecifier how) {
			this.value = value;
			this.envVarName = envVarName;
			this.filename = filename;
			this.how = how;
		}

		public String getValue() {
			return value;
		}

		public String getEnvVarName() {
			return envVarName;
		}

		public String getFilename() {
			return filename;
		}

		public PasswordSpecifier getHow() {
			return how;
		}

		public String getDescription() {
			switch (how) {
			case ENVIRONMENT_VARIABLE:
				return "Retrieved from environment variable \"" + envVarName + "\"";
			case FILE_ENVIRONMENT_VARIABLE:
				return "Retrieved from file \"" + filename + "\" (specified in environment variable \"" + envVarName + "\")";
			case DEFAULT_VALUE:
				return "Using default value";
			default:
				return "Unknown";
			}
		}
	}
}
