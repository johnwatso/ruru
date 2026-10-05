# Third-party notices

## SwiftBot console and Cloudflare integration

Native console styles, headers, cards, rows, Cloudflare API/token/DNS, and
connector supervision code are adapted from
SwiftBot (https://github.com/johnwatso/SwiftBot), under the MIT license:

MIT License

Copyright (c) 2026 johnwatso

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

## DuckDB Swift

Ruru uses the official DuckDB Swift package, pinned to version 1.1.3:
https://github.com/duckdb/duckdb-swift/tree/v1.1.3

Copyright © 2018-2024 Stichting DuckDB Foundation. Licensed under the MIT
license, reproduced in `DuckDB-LICENSE.txt` beside this notice together with the
upstream engine's third-party licenses and notices. The Swift API embeds the
upstream C++ database engine; application-owned code remains Swift.

## cloudflared

The application includes the official Cloudflare connector, version 2026.9.3,
assembled from the upstream Intel and Apple silicon macOS release archives.
Source and release: https://github.com/cloudflare/cloudflared/releases/tag/2026.9.3

Copyright Cloudflare, Inc. Licensed under the Apache License, Version 2.0.
The upstream license is reproduced in cloudflared-LICENSE.txt beside this notice.
The app does not modify the connector's code; its slices are combined and signed
for local development. The vendoring script records the archive SHA-256 digests.
