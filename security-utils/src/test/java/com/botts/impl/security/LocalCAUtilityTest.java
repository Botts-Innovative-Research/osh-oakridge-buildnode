package com.botts.impl.security;

import org.junit.Assert;
import org.junit.Test;
import java.io.File;
import java.nio.file.Files;
import java.security.KeyStore;
import java.security.cert.X509Certificate;
import java.util.Date;

public class LocalCAUtilityTest {

    @Test
    public void testInitialGeneration() throws Exception {
        String keystorePath = "osh-keystore.p12";
        String secretsPath = ".app_secrets";
        String rootCaPath = "root-ca.crt";

        // Clean up
        new File(keystorePath).delete();
        new File(secretsPath).delete();
        new File(rootCaPath).delete();

        LocalCAUtility.checkAndRenewCertificates();

        Assert.assertTrue(new File(keystorePath).exists());
        Assert.assertTrue(new File(secretsPath).exists());
        Assert.assertTrue(new File(rootCaPath).exists());

        String password = Files.readAllLines(new File(secretsPath).toPath()).get(0).trim();
        KeyStore ks = KeyStore.getInstance("PKCS12");
        try (java.io.FileInputStream fis = new java.io.FileInputStream(keystorePath)) {
            ks.load(fis, password.toCharArray());
        }

        Assert.assertTrue(ks.containsAlias("root-ca"));
        Assert.assertTrue(ks.containsAlias("jetty"));

        X509Certificate rootCert = (X509Certificate) ks.getCertificate("root-ca");
        X509Certificate leafCert = (X509Certificate) ks.getCertificate("jetty");

        // Root CA should be ~20 years
        long rootLifespan = rootCert.getNotAfter().getTime() - rootCert.getNotBefore().getTime();
        Assert.assertTrue(rootLifespan > 1000L * 60 * 60 * 24 * 365 * 19);

        // Leaf should be ~1 year
        long leafLifespan = leafCert.getNotAfter().getTime() - leafCert.getNotBefore().getTime();
        Assert.assertTrue(leafLifespan > 1000L * 60 * 60 * 24 * 364);

        // Clean up
        new File(keystorePath).delete();
        new File(secretsPath).delete();
        new File(rootCaPath).delete();
    }
}
