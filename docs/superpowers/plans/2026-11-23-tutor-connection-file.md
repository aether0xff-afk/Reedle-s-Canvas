# Tutor connection file

Continue the user's whole-project goal with tests deferred. The app still requires hand-copying an HTTPS URL and app access token. Add a bounded connection-file import and a private server-side exporter. Never include the BAZE provider key or an actual connection credential in Git, screenshots or the public app ZIP.

- [ ] Define a strict versioned JSON profile: format=reedle.tutor.connection, version=1, server, access_token. Require HTTPS, bounded ASCII app token and at most 8 KiB. Reject unknown/provider-key fields.
- [ ] Import into the existing settings draft. Turn service/automatic transmission off in that draft and require the user to choose usage and Save. No network request or Keychain write occurs just from choosing the file.
- [ ] Add a server-account exporter reading only the app token from environment and writing an atomic user-private file outside the source checkout. Keep credentials out of command-line arguments and output.
- [ ] Provide a Windows wrapper using the already configured encrypted account settings. Document HTTPS deployment and profile handling without requesting device tests.
- [ ] Compile the app without XCTest/pytest. Avoid another simulator rendering pass for settings-only code and keep the previous actual screenshots labeled with their original source.
- [ ] Deliver updated source, record scope and obtain the actual HTTPS server/domain separately; do not fabricate a reachable endpoint or declare the known physical crash fixed.

No additional test cases or device runs are authorized for this pass. Temporary unauthenticated tunnel services are not a substitute for the app's authenticated HTTPS/SSE server contract.
