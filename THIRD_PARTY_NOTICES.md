# Antigravity OAuth compatibility reference

The OAuth desktop client constants, redirect URI, scopes and wire protocol were
adapted from https://github.com/shekohex/opencode-google-antigravity-auth.
The Swift implementation is native and independent; it does not invoke Pi or
reuse any user's Pi credentials. No account rotation or restriction-bypass
mechanisms are included. Read-only discovery probes fixed Google endpoints;
authorization and quota denials do not trigger endpoint retries.

MIT License

Copyright (c) 2025 Jens

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

# pi-antigravity 0.9.0

Project fallback hashing, project/model discovery, runtime grouping, thinking
budgets, CLI-compatible request envelope and streaming protocol were adapted
from https://github.com/Rahularya01/pi-antigravity (installed version 0.9.0).
The compatibility User-Agent retains a tietiezhi third-party marker.

MIT License

Copyright (c) 2026 Rahul Arya

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

TypeWhisperPluginSDK: the plugin links against the installed TypeWhisper
application framework. SDK compile-time metadata is generated from the
upstream v1.7.1 source checkout; see upstream/LICENSE and LICENSE-COMMERCIAL.md.
No SDK runtime binary is distributed inside this plugin.
