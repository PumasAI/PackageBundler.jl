# Generating new public/private keypair on the command-line

First, generate the new keypair:

```shell
ssh-keygen -t rsa -b 4096 -m pem -C "your_email@example.com" -f "./key.pem"
```

When prompted, enter your desired passphrase.

Once the keypair has been generated, you need to rename the public key file:

```shell
mv key.pem.pub key.pub
```

Make sure that you do NOT check your private key into source control.
