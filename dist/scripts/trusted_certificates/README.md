# Additional Trusted Certificates Folder

Place base-64 encoded X.509 certificate files into this directory. They will get loaded at OSH node startup.

The files must have the extension ".pem", ".cer", or ".crt". They will be assumed to be Base-64 encoded X.509 certificate files that look like the following:

```
-----BEGIN CERTIFICATE-----
MIIEMjCCAxqgAwIBAgIBATANBgkqhkiG9w0BAQUFADB7MQswCQYDVQQGEwJHQjEb
   ... lots of base64 text here ...
smPi9WIsgtRqAEFQ8TmDn5XpNpaYbg==
-----END CERTIFICATE-----
```

When a certificate is loaded into a trust store, it is assigned an "alias", which is a short human-readable name. For certificates in this directory, the alias is the filename without its extension. (For example `my_certificate.crt` is loaded with an alias of `my_certificate`.)