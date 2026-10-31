# Persistent signing for this Mac

uiui's earlier local builds were ad-hoc signed. Their designated requirement
contained the executable's hash, so rebuilding changed the identity macOS used
to remember Microphone, Speech Recognition and Accessibility grants.

The app builder now requires a persistent local Code Signing identity named
`uiui Local Code Signing` and its public DER certificate at
`.local-signing/uiui-local.cer`. The private key stays in the user's keychain;
it must never be exported into this checkout, a shell argument or a log.

For this personal development app, create the identity through Keychain Access's
Certificate Assistant, with Identity Type **Self Signed Root** and Certificate
Type **Code Signing**. Keep the key and certificate in the login keychain.
Export only the public certificate in DER `.cer` format to the path above.
Do not add the certificate as a trusted system root or change trust settings.

Every build's designated requirement is constrained to both that certificate's
SHA-1 anchor and `app.uiui.mac`. This is a certificate fingerprint, not a secret
or a choice of signature algorithm. The builder must never replace this with an
identifier-only requirement or silently fall back to ad-hoc signing.

The first transition from an ad-hoc build may need the existing permissions
granted once for the persistent identity. Subsequent rebuilds must preserve the
same certificate and identifier. Test successive builds and normal launches;
do not infer retained permission merely from a successful signature check.

This identity is for this Mac's development use. Public distribution would need
an appropriate Apple-issued signing identity and notarization.


The identity was created with Certificate Assistant in the login keychain; only
the public certificate was exported. Its certificate expires on 23 October 2027.
The bundle's signature and certificate-bound designated requirement verified.
No root trust setting was added. Runtime permission retention across updates is
a separate check.

Apple references: [TN3127](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements),
[Code Signing Tasks](https://developer.apple.com/library/archive/documentation/Security/Conceptual/CodeSigningGuide/Procedures/Procedures.html),
[Requirement Language](https://developer.apple.com/library/archive/documentation/Security/Conceptual/CodeSigningGuide/RequirementLang/RequirementLang.html).
