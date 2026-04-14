# Keet Drop-in Tests

This folder contains standalone Node.js test scripts:

- `01_generate_keet_key.js`
- `02_room_invite_and_chat.js`

## Requirements

- Node.js 18+ (recommended)

## Install dependencies

From the repository root:

```bash
npm --prefix ./Tests install
```

Or from inside this folder:

```bash
npm install
```

## Compile tests (syntax check)

These tests are plain JavaScript, so "compile" runs a syntax validation using `node --check`.

From the repository root:

```bash
npm --prefix ./Tests run compile
```

From inside this folder:

```bash
npm run compile
```

## Run tests

### 1) Generate and validate key material

From the repository root:

```bash
npm --prefix ./Tests run run:key
```

### 2) Create/join room and interactive chat

Create room and stay online:

```bash
npm --prefix ./Tests run run:room -- --name HostUser
```

Create room only (print metadata and exit):

```bash
npm --prefix ./Tests run run:room:create
```

Join an existing room:

```bash
npm --prefix ./Tests run run:room -- --invite pear://keet/<roomId> --name GuestUser
```
