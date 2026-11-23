# Tutor connection file

Continue the user's whole-project goal with tests deferred. The app still requires hand-copying an HTTPS URL and app access token. Add a bounded connection-file import and a private server-side exporter. Never include the BAZE provider key or an actual connection credential in Git, screenshots or the public app ZIP.

- [x] Define a strict versioned JSON profile: format=reedle.tutor.connection, version=1, server, access_token. Require HTTPS, bounded ASCII app token and at most 8 KiB. Reject unknown/provider-key fields.
- [x] Import into the existing settings draft. Turn service/automatic transmission off in that draft and require the user to choose usage and Save. No network request or Keychain write occurs just from choosing the file.
- [x] Add a server-account exporter reading only the app token from environment and writing an atomic user-private file outside the source checkout. Keep credentials out of command-line arguments and output.
- [x] Provide a Windows wrapper using the already configured encrypted account settings. Document HTTPS deployment and profile handling without requesting device tests.
- [x] Compile the app without XCTest/pytest. Actions run 45114890853 succeeded; no simulator was booted or app launched. Previous screenshots retain their original source.
- [x] Prepare the updated source delivery and record its scope. Package has 33 entries, SHA-256 b2b407306e6988addc9bdc1660845233c87359c6c4292b662a1065dff24855aa; bytes match the compiled source.
- [ ] Obtain the actual HTTPS server/domain separately before public deployment or exporting a usable credential-bearing profile. No endpoint has been fabricated; the known physical crash remains unresolved.

No additional test cases or device runs are authorized for this pass. Temporary unauthenticated tunnel services are not a substitute for the app's authenticated HTTPS/SSE server contract.
