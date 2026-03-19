package com.botts.impl.security;

import java.io.File;
import java.io.FileOutputStream;
import java.io.FileWriter;
import java.io.IOException;
import java.math.BigInteger;
import java.nio.file.Files;
import java.nio.file.attribute.PosixFilePermission;
import java.security.*;
import java.security.cert.Certificate;
import java.security.cert.X509Certificate;
import java.util.Date;
import java.util.EnumSet;
import java.util.Set;
import java.util.Base64;
import javax.security.auth.x500.X500Principal;

import org.bouncycastle.asn1.x500.X500Name;
import org.bouncycastle.cert.X509CertificateHolder;
import org.bouncycastle.cert.X509v3CertificateBuilder;
import org.bouncycastle.cert.jcajce.JcaX509CertificateConverter;
import org.bouncycastle.cert.jcajce.JcaX509v3CertificateBuilder;
import org.bouncycastle.operator.ContentSigner;
import org.bouncycastle.operator.jcajce.JcaContentSignerBuilder;
import org.bouncycastle.asn1.x509.BasicConstraints;
import org.bouncycastle.asn1.x509.Extension;

public class EphemeralCAUtility {

    public static void main(String[] args) throws Exception {
        Security.addProvider(new org.bouncycastle.jce.provider.BouncyCastleProvider());

        String keystorePath = "osh-keystore.p12";
        String secretsPath = ".app_secrets";
        String rootCaExportPath = "root-ca.crt";

        if (new File(keystorePath).exists()) {
            System.out.println("Keystore already exists. Skipping generation.");
            return;
        }

        // 1. Generate Keystore Password
        String password = generateRandomPassword(32);
        saveSecret(secretsPath, password);

        // 2. Generate Root CA (In-memory private key)
        KeyPair rootKeyPair = generateKeyPair();
        X509Certificate rootCert = generateCertificate("CN=OSCAR Root CA", "CN=OSCAR Root CA", rootKeyPair.getPublic(), rootKeyPair.getPrivate(), true);

        // 3. Generate Leaf Certificate signed by Root CA
        KeyPair leafKeyPair = generateKeyPair();
        X509Certificate leafCert = generateCertificate("CN=localhost", "CN=OSCAR Root CA", leafKeyPair.getPublic(), rootKeyPair.getPrivate(), false);

        // 4. Save Leaf to Keystore
        saveToKeystore(keystorePath, password, "jetty", leafKeyPair.getPrivate(), new Certificate[]{leafCert, rootCert});

        // 5. Export Public Root CA
        exportCertificate(rootCaExportPath, rootCert);

        System.out.println("Ephemeral CA and Leaf Certificate generated successfully.");
    }

    private static String generateRandomPassword(int length) {
        SecureRandom random = new SecureRandom();
        byte[] bytes = new byte[length];
        random.nextBytes(bytes);
        return Base64.getEncoder().encodeToString(bytes);
    }

    private static void saveSecret(String path, String secret) throws IOException {
        File file = new File(path);
        try (FileWriter writer = new FileWriter(file)) {
            writer.write(secret);
        }
        lockdownFile(file);
    }

    private static void lockdownFile(File file) {
        String os = System.getProperty("os.name").toLowerCase();
        if (os.contains("win")) {
            try {
                java.nio.file.Path path = file.toPath();
                java.nio.file.attribute.AclFileAttributeView view = Files.getFileAttributeView(path, java.nio.file.attribute.AclFileAttributeView.class);
                java.nio.file.attribute.UserPrincipal owner = Files.getOwner(path);
                java.nio.file.attribute.AclEntry entry = java.nio.file.attribute.AclEntry.newBuilder()
                        .setType(java.nio.file.attribute.AclEntryType.ALLOW)
                        .setPrincipal(owner)
                        .setPermissions(java.nio.file.attribute.AclEntryPermission.READ_DATA,
                                        java.nio.file.attribute.AclEntryPermission.WRITE_DATA,
                                        java.nio.file.attribute.AclEntryPermission.APPEND_DATA,
                                        java.nio.file.attribute.AclEntryPermission.READ_NAMED_ATTRS,
                                        java.nio.file.attribute.AclEntryPermission.WRITE_NAMED_ATTRS,
                                        java.nio.file.attribute.AclEntryPermission.READ_ATTRIBUTES,
                                        java.nio.file.attribute.AclEntryPermission.WRITE_ATTRIBUTES,
                                        java.nio.file.attribute.AclEntryPermission.READ_ACL,
                                        java.nio.file.attribute.AclEntryPermission.WRITE_ACL,
                                        java.nio.file.attribute.AclEntryPermission.WRITE_OWNER,
                                        java.nio.file.attribute.AclEntryPermission.SYNCHRONIZE)
                        .build();
                view.setAcl(java.util.Collections.singletonList(entry));
            } catch (IOException e) {
                System.err.println("Failed to set Windows ACLs: " + e.getMessage());
            }
        } else {
            try {
                Set<PosixFilePermission> perms = EnumSet.of(PosixFilePermission.OWNER_READ, PosixFilePermission.OWNER_WRITE);
                Files.setPosixFilePermissions(file.toPath(), perms);
            } catch (Exception e) {
                System.err.println("Failed to set POSIX permissions: " + e.getMessage());
            }
        }
    }

    private static KeyPair generateKeyPair() throws NoSuchAlgorithmException {
        KeyPairGenerator keyGen = KeyPairGenerator.getInstance("RSA");
        keyGen.initialize(2048);
        return keyGen.generateKeyPair();
    }

    private static X509Certificate generateCertificate(String dn, String issuerDn, PublicKey publicKey, PrivateKey signerPrivateKey, boolean isCa) throws Exception {
        X500Name subjectName = new X500Name(dn);
        X500Name issuerName = new X500Name(issuerDn);
        BigInteger serialNumber = BigInteger.valueOf(System.currentTimeMillis());
        Date notBefore = new Date(System.currentTimeMillis() - 1000L * 60 * 60 * 24);
        Date notAfter = new Date(System.currentTimeMillis() + 1000L * 60 * 60 * 24 * 365);

        X509v3CertificateBuilder certBuilder = new JcaX509v3CertificateBuilder(
                issuerName, serialNumber, notBefore, notAfter, subjectName, publicKey);

        if (isCa) {
            certBuilder.addExtension(Extension.basicConstraints, true, new BasicConstraints(true));
        }

        ContentSigner signer = new JcaContentSignerBuilder("SHA256WithRSAEncryption").build(signerPrivateKey);
        X509CertificateHolder certHolder = certBuilder.build(signer);
        return new JcaX509CertificateConverter().setProvider("BC").getCertificate(certHolder);
    }

    private static void saveToKeystore(String path, String password, String alias, PrivateKey privateKey, Certificate[] chain) throws Exception {
        KeyStore ks = KeyStore.getInstance("PKCS12");
        ks.load(null, null);
        ks.setKeyEntry(alias, privateKey, password.toCharArray(), chain);
        try (FileOutputStream fos = new FileOutputStream(path)) {
            ks.store(fos, password.toCharArray());
        }
        lockdownFile(new File(path));
    }

    private static void exportCertificate(String path, X509Certificate cert) throws Exception {
        try (FileOutputStream fos = new FileOutputStream(path)) {
            fos.write(cert.getEncoded());
        }
    }
}
