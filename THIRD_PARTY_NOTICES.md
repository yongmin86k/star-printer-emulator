# Third-party notices

## gnaunited/tsp143-bridge

The Star discovery reply layout (the fixed bytes of the 302-byte `RS1.0.1` reply in
`Sources/StarEmuCore/Network/DiscoveryProtocol.swift`), the ASB frame layout, the ETB counter
encoding and the TCP 9101 status exchange were cross-checked with the reverse-engineering notes and
captures in <https://github.com/gnaunited/tsp143-bridge> (real Star hardware).

```
MIT License

Copyright (c) 2026 Senternal LLC

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
```

## Star Micronics StarIO10 SDK

The StarIO10 SDK was used during development to verify the protocol. It is **not** redistributed in this
repository. "Star Micronics", "StarPRNT", "StarIO"
and "mC-Print" are trademarks of Star Micronics Co., Ltd.; this project is not affiliated with or
endorsed by Star Micronics.

## swift-argument-parser

Apache License 2.0, © Apple Inc. — used by the `staremu` CLI (Swift Package dependency).
