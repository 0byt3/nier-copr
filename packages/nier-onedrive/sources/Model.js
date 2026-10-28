var IMAGE_EXTENSIONS = {
    jpg: true, jpeg: true, png: true, gif: true, webp: true, avif: true, heic: true,
    svg: true, bmp: true, tif: true, tiff: true
}

var VIDEO_EXTENSIONS = {
    mp4: true, mov: true, mkv: true, webm: true, avi: true, m4v: true, mpg: true,
    mpeg: true, wmv: true
}

var AUDIO_EXTENSIONS = {
    mp3: true, flac: true, wav: true, ogg: true, opus: true, m4a: true, aac: true
}

var DOCUMENT_EXTENSIONS = {
    pdf: true, txt: true, md: true, doc: true, docx: true, xls: true, xlsx: true,
    ppt: true, pptx: true, odt: true, ods: true, odp: true, rtf: true, csv: true,
    pages: true, numbers: true, key: true
}

var ARCHIVE_EXTENSIONS = {
    zip: true, tar: true, gz: true, bz2: true, xz: true, zst: true, "7z": true,
    rar: true
}

var CODE_EXTENSIONS = {
    py: true, js: true, ts: true, qml: true, json: true, yaml: true, yml: true,
    toml: true, rs: true, go: true, c: true, h: true, cpp: true, hpp: true,
    java: true, sh: true, nu: true, lua: true, html: true, css: true
}

function parseJsonl(raw) {
    var events = []
    var lines = String(raw || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
        var line = lines[i].trim()
        if (line === "") continue
        try {
            var event = JSON.parse(line)
            if (event && event.schemaVersion === 1) events.push(event)
        } catch (error) {
            // The service can be in the middle of writing the final JSONL record.
        }
    }
    return events
}

function stateTitle(state) {
    var names = {
        "initializing": "Initializing OneDrive",
        "connecting": "Checking network connection",
        "ready": "OneDrive is ready",
        "syncing": "Syncing files",
        "processing": "Processing changes",
        "completed": "Sync complete",
        "completed-with-errors": "Sync completed with errors",
        "offline": "Network unavailable",
        "authentication-required": "Sign in required",
        "action-required": "Action required",
        "error": "OneDrive error"
    }
    return names[String(state || "")] || "Waiting for sync activity"
}

function eventSnapshot(events) {
    var syncState = ""
    var lastError = ""
    var transferByPath = Object.create(null)
    var order = []

    for (var i = 0; i < events.length; i++) {
        var item = events[i]
        var event = item.event
        if (!event || typeof event !== "object") continue
        if (event.state) {
            syncState = String(event.state)
            if (["completed", "completed-with-errors", "initializing"].indexOf(syncState) >= 0) {
                transferByPath = Object.create(null)
                order = []
            }
            if (syncState === "completed") lastError = ""
        }
        if (event.type === "error" || event.type === "configuration-error") {
            lastError = String(event.detail || event.summary || item.message || "")
        }
        if (event.type !== "transfer" || !event.path) continue

        var path = String(event.path)
        if (transferByPath[path] === undefined) order.push(path)
        transferByPath[path] = {
            path: path,
            operation: String(event.operation || "syncing"),
            progress: event.progress === undefined ? null : Number(event.progress),
            complete: event.complete === true,
            sequence: Number(item.sequence || i)
        }
    }

    var transfers = []
    for (var j = 0; j < order.length; j++) {
        var transfer = transferByPath[order[j]]
        if (transfer && !transfer.complete) transfers.push(transfer)
    }
    transfers.sort(function(left, right) { return right.sequence - left.sequence })

    return {
        syncState: syncState,
        statusText: stateTitle(syncState),
        lastError: lastError,
        transfers: transfers.slice(0, 10)
    }
}

// A running monitor alone does not establish a Microsoft connection.
function isConnected(activeState, result, syncState) {
    return activeState === "active" && (result === "" || result === "success")
        && ["ready", "syncing", "processing", "completed", "completed-with-errors", "action-required"].indexOf(syncState) >= 0
}

function displayPath(path, home) {
    path = String(path || "")
    home = String(home || "").replace(/\/+$/, "")
    if (home && path === home) return "~"
    if (home && path.indexOf(home + "/") === 0) return "~" + path.slice(home.length)
    return path
}

function fileExtension(path) {
    var name = String(path || "").split("/").pop().toLowerCase()
    var index = name.lastIndexOf(".")
    return index >= 0 ? name.substring(index + 1) : ""
}

function fileKind(path) {
    var value = String(path || "")
    if (value.endsWith("/")) return "folder"
    var extension = fileExtension(value)
    if (IMAGE_EXTENSIONS[extension]) return "image"
    if (VIDEO_EXTENSIONS[extension]) return "video"
    if (AUDIO_EXTENSIONS[extension]) return "audio"
    if (DOCUMENT_EXTENSIONS[extension]) return "document"
    if (ARCHIVE_EXTENSIONS[extension]) return "archive"
    if (CODE_EXTENSIONS[extension]) return "code"
    return "file"
}

function fileGlyph(path) {
    var glyphs = {
        folder: "󰉋",
        image: "󰋩",
        video: "󰈫",
        audio: "󰎆",
        document: "󰈙",
        archive: "󰀼",
        code: "󰅩",
        file: "󰈔"
    }
    return glyphs[fileKind(path)]
}

function transferText(transfer) {
    var operation = String(transfer.operation || "Syncing")
    operation = operation.charAt(0).toUpperCase() + operation.slice(1)
    if (transfer.progress !== null && isFinite(transfer.progress)) return operation + " · " + Math.round(transfer.progress) + "%"
    return operation
}

if (typeof module !== "undefined") {
    module.exports = {
        displayPath: displayPath,
        isConnected: isConnected,
        parseJsonl: parseJsonl,
        eventSnapshot: eventSnapshot,
        fileKind: fileKind,
        fileGlyph: fileGlyph,
        transferText: transferText
    }
}
