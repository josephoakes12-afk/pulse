# BoringSSL notices

These are complete, unchanged upstream license texts for the two BoringSSL revisions vendored in Pulse's Swift dependencies. They include the applicable third-party terms as well as the primary license. The dependency-root Apache/MIT licenses and NOTICE files are copied separately.

- `CNIOBoringSSL-LICENSE.txt`: SwiftNIO SSL's vendored revision `817ab07ebb53da35afea409ab9328f578492832d`, verified against `swift-nio-ssl/Sources/CNIOBoringSSL/hash.txt`. [Upstream license](https://raw.githubusercontent.com/google/boringssl/817ab07ebb53da35afea409ab9328f578492832d/LICENSE).
- `CCryptoBoringSSL-LICENSE.txt`: Swift Crypto's vendored revision `0226f30467f540a3f62ef48d453f93927da199b6`, verified against `swift-crypto/Sources/CCryptoBoringSSL/hash.txt`. [Upstream license](https://raw.githubusercontent.com/google/boringssl/0226f30467f540a3f62ef48d453f93927da199b6/LICENSE).

`manifest.json` records source URLs, exact revisions and SHA-256 hashes. The bundle builder verifies both the local dependency revision and tracked license bytes before copying these notices into `Contents/Resources/Licenses/BoringSSL/`. Builds never fetch license text from the network. When updating either dependency's vendored revision, review and update its complete upstream license and manifest together.
