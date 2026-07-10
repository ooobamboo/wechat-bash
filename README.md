# welitesh

WeChat Web API shell client — a Bash script that implements the `wx.qq.com`
protocol. Login via QR code, send/receive text messages and files, run as a
background daemon, download media.

## Dependencies

### Required

| Package | Purpose |
|---|---|
| **bash** (≥4.0) | associative arrays |
| **curl** | HTTP requests |
| **jq** | JSON parsing/construction |
| **xmllint** (libxml2) | XML/HTML parsing for login |
| **socat** | Unix domain socket IPC |
| **coreutils** | `od`, `head`, `md5sum`, `stat` |

### Optional

| Package | Purpose |
|---|---|
| **qrencode** | display QR code in terminal (ANSI/UTF8) |
| **fyi** | desktop notifications on incoming messages |
| **chafa** | terminal image preview |

## Install

```bash
git clone git@github.com:ooobamboo/welitesh.git
cd welitesh
chmod +x welite.sh
```

## Usage

### Daemon (background listener)

```bash
./welite.sh -d
```

Scans QR code, then polls for new messages indefinitely. Creates
`welite.sock` for IPC with client instances.

### Send a text message

```bash
./welite.sh <nickname|remark> <message...>
```

### Send a file

```bash
./welite.sh -f <file> <nickname|remark>
```

### Download media by MediaId

```bash
./welite.sh -D <MediaId> <filename>
```

### List contacts

```bash
./welite.sh -l
```

### Runtime files

| File | Purpose |
|---|---|
| `session.json` | persisted login session |
| `welite.sock` | Unix socket for daemon IPC |
| `welite_cookies.txt` | HTTP cookies |
| `welite_contacts.json` | cached contact list |
| `welite_media/` | downloaded images, videos, etc. |
