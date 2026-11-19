# Fixtures

Test inputs. Everything here is made up or used under its licence (see `summaries/LICENSES.txt`). Nothing is a real person's data.

| Path | Used by | What it is |
|---|---|---|
| `dictation1.wav`, `names.wav` | `Scripts/e2e.sh` (dictation) | Short spoken sentences, 16 kHz mono |
| `meeting-me.wav`, `meeting-them.wav` | `Scripts/e2e.sh` (meetings) | Two sides of a short made-up call |
| `echo-me.wav`, `echo-them.wav` | `Scripts/e2e.sh` (meetings) | A call where the other side leaks into the microphone |
| `article.*`, `book.epub`, `book-parts.epub` | `Scripts/e2e.sh` (read aloud, documents) | One article in each format Chirp opens |
| `agenda.txt`, `screen.png` | `Scripts/e2e.sh` (meeting notes) | A calendar agenda and a screen the notes read from |
| `documents/` | `Scripts/e2e.sh` and trying Chirp by hand | Rich text, Markdown and a saved web page, with deliberate mistakes |
| `summaries/` | ChirpCore unit tests, `Scripts/e2e.sh` (summaries) | Pages, emails and READMEs to summarize, with `checklist.json`: the points a good summary keeps |

Open a copy of a document rather than fixing the original, or run `git checkout Fixtures` afterwards.
