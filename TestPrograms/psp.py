#!/usr/bin/env python3
"""Builds a small PSP test program (EBOOT.PBP) for PPSSPP.

It shows ATTIC PSP, a turning cube drawn by the PSP's GPU, a lamp per button and a dot that
follows the analog stick (TestPrograms/psp/main.c). Unlike the other test programs it is C,
built with the open-source PSPSDK: get pspdev from github.com/pspdev/pspdev (Releases) and pass
its folder with --pspdev, or set PSPDEV.
Usage: python3 TestPrograms/psp.py <out.pbp> [--pspdev /path/to/pspdev]
"""
import argparse
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from font import pixels  # noqa: E402

TEXT = "ATTIC PSP"


def text_header():
    cells = list(pixels(TEXT))
    width = (len(TEXT) * 6 - 1) * 4
    rows = ",\n".join(f"    {{{x}, {y}}}" for x, y in cells)
    return (f"// {TEXT} in the test programs' 5x7 letters, written by TestPrograms/psp.py.\n"
            f"#define TEXT_PIXELS {len(cells)}\n"
            f"#define TEXT_LEFT {(480 - width) // 2}\n"
            f"static const short text_pixels[TEXT_PIXELS][2] = {{\n{rows}\n}};\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("output")
    parser.add_argument("--pspdev", default=os.environ.get("PSPDEV"), help="the pspdev folder")
    args = parser.parse_args()
    if not args.pspdev:
        sys.exit("Needs pspdev: pass --pspdev /path/to/pspdev or set PSPDEV")

    environment = dict(os.environ, PSPDEV=args.pspdev,
                       PATH=os.path.join(args.pspdev, "bin") + os.pathsep + os.environ["PATH"])
    with tempfile.TemporaryDirectory() as build:
        for name in ["main.c", "Makefile"]:
            shutil.copy(os.path.join(HERE, "psp", name), build)
        with open(os.path.join(build, "text.h"), "w") as file:
            file.write(text_header())
        subprocess.run(["make", "-s"], cwd=build, env=environment, check=True)
        shutil.copy(os.path.join(build, "EBOOT.PBP"), args.output)
    print(f"{args.output} written")


if __name__ == "__main__":
    main()
