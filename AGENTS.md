# Project Instructions

- Repository overview: Windows troubleshooting scripts for recurring Codex proxy and reconnect failures.
- Important directories: final scripts belong in `outputs/`; temporary test artifacts belong in `work/`.
- Entry points: `outputs/一键修复Codex重连.bat` and `outputs/修复Codex重连.ps1`.
- Build: not applicable.
- Test/status command: `powershell -NoProfile -ExecutionPolicy Bypass -File "outputs/修复Codex重连.ps1" -Action Status`.
- Coding conventions: prefer PowerShell for logic and keep batch files as thin wrappers.
- Architecture rule: proxy detection, backup, mutation, rollback, and restart logic stay in the PowerShell script.
- This workspace contains user-facing troubleshooting deliverables.
- Put final deliverables in `outputs/`.
- Put temporary files and test artifacts in `work/`.
- Prefer PowerShell for Windows automation.
- Scripts that change user settings must support status inspection and rollback.
- Do not store credentials, tokens, cookies, or session data.
- Do not change proxy environment variable names or backup format without preserving rollback compatibility.
- Do not add dependencies for this standalone Windows script.
- Verification checklist: parse the PowerShell script, run batch `status`, and confirm install/remove paths remain available.
- Definition of done: scripts are syntax-valid, status works without mutation, repair has a connection test, and rollback remains documented.
