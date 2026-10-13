#!/usr/bin/env bash
# Writes a made-up Roger library for screenshots of the library window:
# log entries over three days, two meetings (one with screenshots and the
# extra files a retry leaves), one file transcript and one unfinished
# meeting. The files use the format Roger writes. Nothing here is real data.
#
# Usage: scripts/make-sample-library.sh <folder>
# The folder must not exist yet, or be empty.
set -euo pipefail

if [ $# -ne 1 ]; then
  echo "usage: $0 <folder>" >&2
  exit 1
fi
root=$1
if [ -e "$root" ] && [ -n "$(ls -A "$root")" ]; then
  echo "error: $root is not empty" >&2
  exit 1
fi
mkdir -p "$root"

version="0.24.0"
model="FluidInference/parakeet-ultra-coreml"
diarizer="FluidInference/speaker-diarization-coreml"

# Local UTC offset as +02:00 (RFC 3339), the form Roger writes.
raw_offset=$(date +%z)
offset="${raw_offset:0:3}:${raw_offset:3:2}"

ts() { echo "${1}T${2}${offset}"; }

# Seconds since midnight for HH:MM:SS.
secs() { echo "$1" | awk -F: '{ print $1 * 3600 + $2 * 60 + $3 }'; }

# HH:MM:SS of a second count.
hms() { printf '%02d:%02d:%02d' $(($1 / 3600)) $((($1 % 3600) / 60)) $(($1 % 60)); }

# log <day> <HH:MM:SS> <duration s> <preset> <text>
log() {
  local day=$1 time=$2 duration=$3 preset=$4 text=$5
  local year=${day:0:4} month=${day:5:2} clock=${time:0:5}
  local folder="$root/Logs/$year/$month"
  local name="$day ${time//:/-}"
  local end
  end=$(hms $(( $(secs "$time") + duration )))
  local snippet
  snippet=$(echo "$text" | awk '{ s = ""; for (i = 1; i <= 6 && i <= NF; i++) s = s (i > 1 ? " " : "") $i; sub(/[,.;:!?]+$/, "", s); print s }')
  mkdir -p "$folder"
  : > "$folder/$name.m4a"
  cat > "$folder/$name.md" <<EOF
---
type: source
title: "Log $day $clock - $snippet"
description: "Log entry recorded with Roger on $day at $clock."
tags: [log]
generated: { by: roger/$version, model: "$model", at: $(ts "$day" "$end") }
recorded_at: $day
source_date: $day
temporal_confidence: explicit
sources:
  - { id: audio, resource: "$name.m4a" }
status: stable
started_at: $(ts "$day" "$time")
ended_at: $(ts "$day" "$end")
duration_seconds: $duration
preset: "$preset"
language: "en"
---

# Log $day $clock

$text
EOF
}

# A slide-like 1280x720 PNG: light page, a coloured title band and bars.
# slide <file> <r> <g> <b>
slide() {
  local out=$1 bmp
  bmp=$(mktemp -t roger-slide).bmp
  perl -e '
    my ($file, $r, $g, $b) = @ARGV;
    my ($w, $h) = (1280, 720);
    my @bars = (0.82, 0.64, 0.71, 0.45, 0.58);
    open(my $fh, ">:raw", $file) or die $!;
    my $size = 54 + $w * $h * 3;
    print $fh pack("A2 V v v V V l l v v V V l l V V", "BM", $size, 0, 0, 54, 40, $w, $h, 1, 24, 0, $w * $h * 3, 2835, 2835, 0, 0);
    for my $row (0 .. $h - 1) {
      my $y = $h - 1 - $row;   # BMP rows run bottom-up
      my $line = "";
      for my $x (0 .. $w - 1) {
        my @c = (246, 246, 243);
        if ($y < 120) {
          @c = ($r, $g, $b);
        } elsif ($y >= 200 && $y < 640 && $x >= 120) {
          my $i = int(($y - 200) / 88);
          my $in = ($y - 200) % 88;
          @c = ($r * 0.7 + 70, $g * 0.7 + 70, $b * 0.7 + 70)
            if $in >= 20 && $in < 68 && $x < 120 + $bars[$i] * 1040;
        }
        $line .= pack("CCC", $c[2], $c[1], $c[0]);
      }
      print $fh $line;
    }
    close $fh;
  ' "$bmp" "$2" "$3" "$4"
  sips -s format png "$bmp" --out "$out" >/dev/null
  rm -f "$bmp"
}

# MARK: Log entries

log 2026-10-10 08:52:14 41 "Polished" \
"Weekend session on the Harbor sync rewrite. The plan is to move conflict handling out of the client and into the service, so the mobile apps stop guessing. First step is a small spike to see how much of the old merge code we can keep."

log 2026-10-10 13:37:02 28 "Polished" \
"The spike looks good. About two thirds of the merge code can stay. The tricky part is deleted folders: the old client resurrects them when an offline device comes back. I want a test for exactly that case before I change anything."

log 2026-10-10 17:05:48 35 "Plain" \
"Note for the roadmap review on Monday. We should drop the export wizard from the autumn release and ship the sync fixes instead. Fewer features, but the ones people complain about most."

log 2026-10-11 09:14:30 52 "Professional" \
"Wrote the failing test for the deleted folder case. It reproduces the bug in under a second, which is great. Next I will add a tombstone record on the server and let the client ask for it during the first sync after a long offline period."

log 2026-10-11 15:48:11 24 "Polished" \
"Tombstones work. The resurrected folder test is green, and the full suite still passes. I still need to decide how long the server keeps tombstones. Thirty days feels safe, but storage might not like it."

log 2026-10-12 08:31:05 33 "Plain" \
"Coffee thoughts before the roadmap meeting. If we keep tombstones for thirty days, we need a cleanup job and a metric for it. Ask Priya whether the storage team has numbers for a similar case."

log 2026-10-12 16:22:47 46 "Polished" \
"Good outcome from the roadmap meeting. Export wizard moves to next year, sync fixes go first. Priya thinks thirty days of tombstones is fine. Tomorrow I write the cleanup job and the release notes draft."

# MARK: Meeting with screenshots and retry leftovers

day=2026-10-12; start=10:00:00
mtg="$root/Meetings/2026/10/2026-10-12 10-00"
mkdir -p "$mtg"
: > "$mtg/mic.m4a"
: > "$mtg/system.m4a"
: > "$mtg/mic.leftover.m4a"
slide "$mtg/2026-10-12 10-03-12.png" 52 103 196
slide "$mtg/2026-10-12 10-11-40.png" 214 104 64

paragraphs() {
  cat <<EOF
**Speaker 1** [00:00:04 · $day 10:00:04]
Okay, let's start. The goal for today is to agree on the autumn roadmap, and I want us to leave with one list, not three.

**Speaker 2** [00:01:15 · $day 10:01:15]
Sure. From the support side the message is clear. Most tickets are about sync, folders that come back after you delete them, and files that show up twice.

![Screenshot at 00:03:12 · $day 10:03:12](2026-10-12%2010-03-12.png)

**Speaker 1** [00:03:20 · $day 10:03:20]
This slide shows the ticket count per area for the last quarter. Sync is almost half of it. Export is a small bar at the bottom.

**Speaker 3** [00:05:02 · $day 10:05:02]
So the export wizard can wait. I would rather ship the tombstone fix and a cleanup job than a feature few people asked for.

**Speaker 2** [00:07:45 · $day 10:07:45]
How long do we keep the tombstones on the server?

**Speaker 3** [00:08:10 · $day 10:08:10]
Thirty days. The storage numbers from a similar case say that is fine, as long as the cleanup job runs every night.

![Screenshot at 00:11:40 · $day 10:11:40](2026-10-12%2010-11-40.png)

**Speaker 1** [00:11:48 · $day 10:11:48]
Here is the updated roadmap. Sync fixes first, then the cleanup job, export wizard moves to next year. Any objections?

**Speaker 2** [00:12:30 · $day 10:12:30]
None from me. I will tell the support team so they can answer the open tickets.

EOF
}

cat > "$mtg/transcript.previous.md" <<EOF
---
type: source
title: "Meeting $day 10:00"
description: "Meeting transcript, 13 minutes, 3 speakers, 2 slide screenshots, recorded and transcribed on this Mac by Roger."
tags: [meeting, transcript]
generated: { by: roger/$version, model: "$model", at: $(ts "$day" 10:14:20) }
recorded_at: $day
source_date: $day
temporal_confidence: explicit
sources:
  - { id: mic, resource: "mic.m4a" }
status: stable
started_at: $(ts "$day" 10:00:00)
ended_at: $(ts "$day" 10:13:05)
duration_seconds: 785
speaker_count: 3
screenshot_count: 2
language: "en"
system_audio_failed: true
---

# Meeting $day 10:00

$(paragraphs)
EOF

cat > "$mtg/transcript.md" <<EOF
---
type: source
title: "Meeting $day 10:00"
description: "Meeting transcript, 13 minutes, 3 speakers, 2 slide screenshots, recorded and transcribed on this Mac by Roger."
tags: [meeting, transcript]
generated: { by: roger/$version, model: "$model", at: $(ts "$day" 10:31:02) }
recorded_at: $day
source_date: $day
temporal_confidence: explicit
sources:
  - { id: mic, resource: "mic.m4a" }
  - { id: system, resource: "system.m4a" }
  - { id: mic-leftover, resource: "mic.leftover.m4a" }
status: stable
started_at: $(ts "$day" 10:00:00)
ended_at: $(ts "$day" 10:13:05)
duration_seconds: 785
speaker_count: 3
screenshot_count: 2
language: "en"
diarization_model: "$diarizer"
---

# Meeting $day 10:00

$(paragraphs)
EOF

# MARK: Plain meeting

day=2026-10-11
mtg="$root/Meetings/2026/10/2026-10-11 11-30"
mkdir -p "$mtg"
: > "$mtg/mic.m4a"
: > "$mtg/system.m4a"
cat > "$mtg/transcript.md" <<EOF
---
type: source
title: "Meeting $day 11:30"
description: "Meeting transcript, 6 minutes, 2 speakers, recorded and transcribed on this Mac by Roger."
tags: [meeting, transcript]
generated: { by: roger/$version, model: "$model", at: $(ts "$day" 11:37:40) }
recorded_at: $day
source_date: $day
temporal_confidence: explicit
sources:
  - { id: mic, resource: "mic.m4a" }
  - { id: system, resource: "system.m4a" }
status: stable
started_at: $(ts "$day" 11:30:00)
ended_at: $(ts "$day" 11:36:12)
duration_seconds: 372
speaker_count: 2
language: "en"
diarization_model: "$diarizer"
---

# Meeting $day 11:30

**Speaker 1** [00:00:03 · $day 11:30:03]
Thanks for joining. I mainly want to check the storage side of the tombstone idea before the roadmap meeting tomorrow.

**Speaker 2** [00:00:41 · $day 11:30:41]
We did something similar for the photo service last year. Each tombstone is tiny, a few hundred bytes. Even with a lot of deletes, thirty days is not a problem.

**Speaker 1** [00:02:18 · $day 11:32:18]
Good. Do we need a cleanup job, or does the database expire them for us?

**Speaker 2** [00:02:55 · $day 11:32:55]
I would write a small nightly job. It is easier to watch, and you get a metric for free.

**Speaker 1** [00:05:30 · $day 11:35:30]
Perfect. I will put that on the list for this week.

EOF

# MARK: File transcript

day=2026-10-10
tr="$root/Transcripts/2026/10"
mkdir -p "$tr"
cat > "$tr/Product podcast episode 12.md" <<EOF
---
type: source
title: "Product podcast episode 12"
description: "Transcript of an audio recording, 9 minutes, 2 speakers, transcribed on this Mac by Roger."
resource: "../../../Media/Product podcast episode 12.m4a"
tags: [transcript]
generated: { by: roger/$version, model: "$model", at: $(ts "$day" 20:12:09) }
recorded_at: $day
source_date: $day
temporal_confidence: explicit
sources:
  - { id: media, resource: "../../../Media/Product podcast episode 12.m4a", last_modified: $(ts "$day" 19:40:00) }
status: stable
started_at: $(ts "$day" 19:00:00)
ended_at: $(ts "$day" 19:09:20)
duration_seconds: 560
speaker_count: 2
language: "en"
diarization_model: "$diarizer"
---

# Product podcast episode 12

**Speaker 1** [00:00:02 · $day 19:00:02]
Welcome back to the show. Today we talk about saying no to features, and why a short roadmap is often the better roadmap.

**Speaker 2** [00:01:10 · $day 19:01:10]
I like that topic. Every team I know has a list of ideas that is ten times longer than what they can build. The hard part is not finding ideas, it is choosing.

**Speaker 1** [00:03:45 · $day 19:03:45]
And how do you choose?

**Speaker 2** [00:04:02 · $day 19:04:02]
Look at what hurts people today. Support tickets are an honest signal. If half of them are about one area, that area goes first, even if it is not exciting.

EOF

# MARK: Unfinished meeting

mtg="$root/Meetings/2026/10/2026-10-13 09-15"
mkdir -p "$mtg"
head -c 4096 /dev/zero > "$mtg/mic-001.caf"

echo "Sample library written to $root"
