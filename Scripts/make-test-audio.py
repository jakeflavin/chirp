#!/usr/bin/env python3
"""Makes the spoken test clips in Fixtures/ with macOS's built-in synthetic voices (`say`), so no real person's voice
is in the repository. Scripts/e2e.sh checks words in these clips: change the lines here and the checks together.

Usage: python3 -I Scripts/make-test-audio.py        (writes Fixtures/*.wav, 16 kHz mono 16-bit)
"""
import array
import os
import random
import subprocess
import sys
import tempfile
import wave

RATE = 16000
FIXTURES = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "Fixtures")
ME, HOST, GUEST = "Samantha", "Daniel", "Karen"


def speak(voice, text):
    """One line in one voice, as 16 kHz mono samples."""
    with tempfile.TemporaryDirectory() as folder:
        aiff, wav = os.path.join(folder, "line.aiff"), os.path.join(folder, "line.wav")
        subprocess.run(["say", "-v", voice, "-o", aiff, text], check=True)
        subprocess.run(["afconvert", "-f", "WAVE", "-d", f"LEI16@{RATE}", "-c", "1", aiff, wav], check=True)
        with wave.open(wav) as w:
            return array.array("h", w.readframes(w.getnframes()))


def silence(seconds):
    return array.array("h", bytes(2 * int(seconds * RATE)))


def write(name, samples):
    with wave.open(os.path.join(FIXTURES, name), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(samples.tobytes())
    print(f"{name}: {len(samples) / RATE:.1f} s")


def conversation(turns, gap=0.7):
    """Two tracks of the same length: what I say (microphone) and what the other side says (the Mac's sound)."""
    mine, theirs = silence(0.5), silence(0.5)
    for who, voice, text in turns:
        line = speak(voice, text)
        quiet = silence(len(line) / RATE)
        mine.extend(line if who == "me" else quiet)
        theirs.extend(quiet if who == "me" else line)
        mine.extend(silence(gap))
        theirs.extend(silence(gap))
    return mine, theirs


def with_echo(mine, theirs, level=0.35, delay=0.03, noise=60):
    """The microphone as it is in a room with loudspeakers: my voice, plus the other side a little late and quieter,
    plus a little noise."""
    random.seed(7)
    shift = int(delay * RATE)
    out = array.array("h", mine)
    for i in range(len(out)):
        leak = theirs[i - shift] if i >= shift else 0
        out[i] = max(-32768, min(32767, int(out[i] + level * leak + random.randint(-noise, noise))))
    return out


def main():
    if sys.platform != "darwin":
        sys.exit("This uses macOS's `say` and `afconvert`.")

    write("dictation1.wav", speak(ME, "So, um, I was thinking we should move the meeting to Thursday. No, wait, Friday at "
                                      "3 p.m., because Maya is out. Can you send me the quarter 3 numbers before then? Thanks."))
    # The name is one speech models get wrong until it's in the dictionary.
    write("names.wav", speak(ME, "Please ask Saoirse Okafor to deploy the new build on Kubernetes before the stand-up."))

    mine, theirs = conversation([
        ("them", HOST, "Thanks for joining, everyone. Let's review the launch plan. The beta goes out on March 3rd, and we need two more testers."),
        ("me", ME, "Sounds good. I will send the budget numbers by Wednesday."),
        ("them", GUEST, "I can own the release notes. Marketing needs the final screenshots by Friday, so please send them to me."),
        ("me", ME, "I can find the two testers this week."),
        ("them", HOST, "Great. One risk is the payment bug. Kate will fix it before the beta. Let's meet again next Tuesday."),
    ])
    write("meeting-me.wav", mine)
    write("meeting-them.wav", theirs)

    mine, theirs = conversation([
        ("them", HOST, "Thanks for joining. The first thing is the launch date. Testing needs four more weeks. So April is the honest date, not March."),
        ("me", ME, "If we say April, what does that do to the payments work?"),
        ("them", GUEST, "I agree with April. The payments provider is the one risk left. If their interface changes, we have to rewrite the checkout page."),
        ("me", ME, "So no new features until testing passes. I am fine with that, and I will write the release notes."),
        ("them", HOST, "Then we decide today. Launch moves to April, and nothing new goes in until the tests pass."),
    ])
    write("echo-me.wav", with_echo(mine, theirs))
    write("echo-them.wav", theirs)


if __name__ == "__main__":
    main()
