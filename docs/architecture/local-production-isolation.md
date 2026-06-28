# Local production install isolation

RepoPrompt CE supports local production builds that use a personal display name, bundle ID, URL scheme, and filesystem namespace. MitchPrompt CE is one such install.

## Namespace source of truth

`RepoPromptApplicationSupportDirectoryName` in the app `Info.plist` is the runtime namespace source of truth. If the key is missing or invalid, runtime code falls back to the canonical public namespace:

```text
RepoPrompt CE
```

For MitchPrompt CE the key is:

```text
MitchPrompt CE
```

`MCPFilesystemIdentity.currentRepoPromptCE(_:)` reads that key for both the app and the bundled `repoprompt-mcp` helper. The helper also walks up to the containing `.app/Contents/Info.plist` so symlinked or directly invoked helpers use the same namespace as the app bundle that contains them.

## Isolated surfaces

A non-canonical namespace changes all user-data and MCP runtime paths that must not collide with the public RepoPrompt CE install:

- Application Support root, such as `~/Library/Application Support/MitchPrompt CE/`
- MCP socket directory and socket name, such as `/tmp/mitchprompt-ce-mcp-<uid>/mitchprompt-ce-7.sock`
- MCP events and kill-signal directories
- MCP config and routing files
- user-space CLI helper link and displayed CLI command name
- exported MCP server name, such as `MitchPromptCE`
- prompt, context-builder prompt, preset, setting, workspace, chat, window-session, pi-model-cache, pi-bridge, device-id, and local-signing registry files

Canonical public and debug builds keep the existing names exactly, including `RepoPrompt CE`, `repoprompt-ce-7.sock`, `repoprompt-ce-D-7.sock`, `rpce-cli`, and `rpce-cli-debug`.

## Packaging contract

`Scripts/package_app.sh` writes `RepoPromptApplicationSupportDirectoryName` into `Info.plist`. By default it uses `DISPLAY_NAME`; callers can override it with `REPOPROMPT_APPLICATION_SUPPORT_DIRECTORY_NAME` or `APP_SUPPORT_DIRECTORY_NAME`.

`Scripts/install_local_production.sh` passes the same namespace into packaging and validates the packaged plist before installing. For MitchPrompt CE use:

```bash
CONFIRM_LOCAL_PRODUCTION_INSTALL=1 \
LOCAL_PRODUCTION_SIGNING_MODE=developer-id \
DISPLAY_NAME="MitchPrompt CE" \
BUNDLE_ID=com.mitchfultz.repoprompt.ce \
REPOPROMPT_URL_SCHEME=mitchprompt-ce \
REPOPROMPT_APPLICATION_SUPPORT_DIRECTORY_NAME="MitchPrompt CE" \
./Scripts/install_local_production.sh
```

## Migration behavior

The canonical public namespace is unchanged, so public RepoPrompt CE users keep existing data in place. Paths that previously lived outside the CE namespace (`com.pvncher.repoprompt` prompts and `com.repoprompt` device ID) are copied forward on first read into the active namespace when the active file is missing.
