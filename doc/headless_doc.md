# Venera Headless Mode

Venera's headless mode allows you to run key features from the command line, making it easy to automate tasks and integrate with other tools. This document outlines the available commands and their usage.

Headless uses the same bootstrap as the GUI: appdata and required components are initialized first,
then the source registry is discovered without executing legacy JavaScript, Cloud admission is
prepared, and only after that are the JS engine, source manager, and Cloud coordinator started.
The follow-up master switch does not relax source ownership.

## How to Use

To activate headless mode, use the `--headless` flag when running the Venera executable, followed by the desired command.

```bash
venera --headless <command> [subcommand] [options]
```

## Global Options

- **`--ignore-disheadless-log`**: Suppresses log output, providing a cleaner output for scripting.

## Commands

### `webdav`

Manage WebDAV data synchronization.

- **`webdav up`**: Uploads your local configuration to the WebDAV server.
- **`webdav down`**: Downloads and applies the remote configuration from the WebDAV server.

**Example:**

```bash
venera --headless webdav up
```

### `updatescript`

Update comic source scripts.

- **`updatescript all`**: Checks for and applies all available updates for your comic source scripts.

With Cloud enabled, managed updates are limited to the current trusted authority `activeRevision`
and the exact installed catalog artifacts. The command cannot install a custom URL or silently
restore a legacy custom script. Cloud-off keeps the verified pinned selection; an old custom script
requires an explicit recovery/edit action through the same mutation service.

**Example:**

```bash
venera --headless updatescript all
```

**Output Format:**

The `updatescript` command provides detailed progress and a final summary.

**Progress Logs:**

- **`Progress`**: Indicates a successful update for a single script.
- **`ProgressError`**: Indicates a failure during a script update.

**Example `Progress` Log:**

```json
{
  "status": "running",
  "message": "Progress",
  "data": {
    "current": 1,
    "total": 5,
    "source": {
      "key": "source-key",
      "name": "Source Name",
      "version": "1.0.0",
      "url": "https://example.com/source.js"
    }
  }
}
```

**Final Summary:**

A summary is provided at the end, detailing the total number of scripts, how many were updated, and how many failed.

```json
{
  "status": "success",
  "message": "All scripts updated.",
  "data": {
    "total": 5,
    "updated": 4,
    "errors": 1
  }
}
```

### `updatesubscribe`

Update your subscribed comics and retrieve a list of updated comics.

- **`updatesubscribe`**: Checks all subscribed comics for updates.
- **`updatesubscribe --update-comic-by-id-type <id> <type>`**: Updates a single comic specified by its `id` and `type`.

Scanning follows the runtime admission and generation fence prepared during startup. A Local-only
artifact uses its pinned script locally; a Cloud-capable artifact contributes interests only after
exact revision/path/hash admission. Missing, blocked, or authority-unavailable artifacts remain
paused instead of falling back to a custom or stale runtime.

## Data sync and source import boundaries

WebDAV/app-data import still handles the ordinary app, history, and cookie data according to the
existing validation rules. When an archive contains `comic_source/` files and Cloud is enabled (or
is being enabled), source scripts and registry replacement are skipped and the import result marks
the source portion as not imported; existing active files are not deleted first. Cloud-off import
uses the shared mutation fence and reload path, and a mode change during the operation aborts and
restores the previous source directory.

**Example:**

```bash
# Update all subscriptions
venera --headless updatesubscribe

# Update a single comic
venera --headless updatesubscribe --update-comic-by-id-type "comic-id" "source-key"
```

## Output Format

All headless commands output JSON objects prefixed with `[CLI PRINT]`. This structured format allows for easy parsing in automated scripts. The JSON object always contains a `status` and a `message`. For commands that return data, a `data` field will also be present.

### `updatesubscribe` Output

The `updatesubscribe` command provides detailed progress and final results in JSON format.

**Progress Logs:**

During an update, you will receive `Progress` or `ProgressError` messages.

- **`Progress`**: Indicates a successful step in the update process.
- **`ProgressError`**: Indicates an error occurred while updating a specific comic.

**Example `Progress` Log:**

```json
{
  "status": "running",
  "message": "Progress",
  "data": {
    "current": 1,
    "total": 10,
    "comic": {
      "id": "some-comic-id",
      "name": "Some Comic Name",
      "coverUrl": "https://example.com/cover.jpg",
      "author": "Author Name",
      "type": "source-key",
      "updateTime": "2023-10-27T12:00:00Z",
      "tags": ["tag1", "tag2"]
    }
  }
}
```

**Example `ProgressError` Log:**

```json
{
  "status": "running",
  "message": "ProgressError",
  "data": {
    "current": 2,
    "total": 10,
    "comic": {
      "id": "another-comic-id",
      "name": "Another Comic Name",
      ...
    },
    "error": "Error message here"
  }
}
```

**Final Output:**

Once the update process is complete, a final JSON object is returned with a list of all comics that have been updated.

```json
{
  "status": "success",
  "message": "Updated comics list.",
  "data": [
    {
      "id": "some-comic-id",
      "name": "Some Comic Name",
      "coverUrl": "https://example.com/cover.jpg",
      "author": "Author Name",
      "type": "source-key",
      "updateTime": "2023-10-27T12:00:00Z",
      "tags": ["tag1", "tag2"]
    }
  ]
}
