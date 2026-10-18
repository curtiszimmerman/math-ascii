# IRC color codes

Source: https://modern.ircdocs.horse/formatting.html (fetched 2026-10-17).

A color code is `\x03` followed by a foreground number and optionally `,` and a
background number. If two digits follow `\x03`, clients always read two, so we
always write two-digit codes (`\x0304,88`) to keep art text that starts with a
digit from being swallowed. A fg-only code followed by text like `,13` gets read
as a background, which is another reason to always write the full `fg,bg` pair.

Colors 0-15 are client-defined, so their RGB varies. Colors 16-98 have fixed RGB
values, which makes them the safe choice for art that should look the same
everywhere. 99 means "default".

| Code | RGB | ANSI | Code | RGB | ANSI | Code | RGB | ANSI |
|------|-----|------|------|-----|------|------|-----|------|
| 16 | 470000 | 52 | 40 | b50000 | 124 | 64 | ff5959 | 203 |
| 17 | 472100 | 94 | 41 | b56300 | 166 | 65 | ffb459 | 215 |
| 18 | 474700 | 100 | 42 | b5b500 | 184 | 66 | ffff71 | 227 |
| 19 | 324700 | 58 | 43 | 7db500 | 106 | 67 | cfff60 | 191 |
| 20 | 004700 | 22 | 44 | 00b500 | 34 | 68 | 6fff6f | 83 |
| 21 | 00472c | 29 | 45 | 00b571 | 49 | 69 | 65ffc9 | 122 |
| 22 | 004747 | 23 | 46 | 00b5b5 | 37 | 70 | 6dffff | 87 |
| 23 | 002747 | 24 | 47 | 0063b5 | 33 | 71 | 59b4ff | 111 |
| 24 | 000047 | 17 | 48 | 0000b5 | 19 | 72 | 5959ff | 63 |
| 25 | 2e0047 | 54 | 49 | 7500b5 | 129 | 73 | c459ff | 177 |
| 26 | 470047 | 53 | 50 | b500b5 | 127 | 74 | ff66ff | 207 |
| 27 | 47002a | 89 | 51 | b5006b | 161 | 75 | ff59bc | 205 |
| 28 | 740000 | 88 | 52 | ff0000 | 196 | 76 | ff9c9c | 217 |
| 29 | 743a00 | 130 | 53 | ff8c00 | 208 | 77 | ffd39c | 223 |
| 30 | 747400 | 142 | 54 | ffff00 | 226 | 78 | ffff9c | 229 |
| 31 | 517400 | 64 | 55 | b2ff00 | 154 | 79 | e2ff9c | 193 |
| 32 | 007400 | 28 | 56 | 00ff00 | 46 | 80 | 9cff9c | 157 |
| 33 | 007449 | 35 | 57 | 00ffa0 | 86 | 81 | 9cffdb | 158 |
| 34 | 007474 | 30 | 58 | 00ffff | 51 | 82 | 9cffff | 159 |
| 35 | 004074 | 25 | 59 | 008cff | 75 | 83 | 9cd3ff | 153 |
| 36 | 000074 | 18 | 60 | 0000ff | 21 | 84 | 9c9cff | 147 |
| 37 | 4b0074 | 91 | 61 | a500ff | 171 | 85 | dc9cff | 183 |
| 38 | 740074 | 90 | 62 | ff00ff | 201 | 86 | ff9cff | 219 |
| 39 | 740045 | 125 | 63 | ff0098 | 198 | 87 | ff94d3 | 212 |

Grayscale:

| Code | RGB | ANSI |
|------|-----|------|
| 88 | 000000 | 16 |
| 89 | 131313 | 233 |
| 90 | 282828 | 235 |
| 91 | 363636 | 237 |
| 92 | 4d4d4d | 239 |
| 93 | 656565 | 241 |
| 94 | 818181 | 244 |
| 95 | 9f9f9f | 247 |
| 96 | bcbcbc | 250 |
| 97 | e2e2e2 | 254 |
| 98 | ffffff | 231 |
