#!/usr/bin/env python3
"""Build the run-guide PDF for Hands-On Microservices with Spring Boot and Spring Cloud.

Assembled only from files that exist on disk: PROGRESS.md plus every
ChapterNN/FINDINGS/FINDINGS.md. No content is invented -- if a chapter is missing
it is reported as not-run rather than filled in.
"""
import pathlib
import re
import sys

import pymupdf

ROOT = pathlib.Path("/home/champion/springbook")
OUT = ROOT / "Spring-Microservices-Run-Guide.pdf"

CHAPTERS = [
    "Chapter03", "Chapter04", "Chapter05", "Chapter06", "Chapter07",
    "Chapter09", "Chapter10", "Chapter11", "Chapter12", "Chapter13",
    "Chapter14", "Chapter15", "Chapter16", "Chapter17", "Chapter18",
    "Chapter19", "Chapter20",
]

MONO = "cour"
SANS = "helv"


def wrap(text, width, fontsize, font=MONO):
    """Greedy wrap that respects code fences."""
    out = []
    for para in text.split("\n"):
        if not para.strip():
            out.append("")
            continue
        indent = len(para) - len(para.lstrip())
        prefix = "" if indent <= 2 else "    * "
        line = ""
        for word in para.split():
            if not line:
                line = word
            elif char_width(line + " " + word) <= width:
                line += " " + word
            else:
                out.append(prefix + line if prefix else line)
                line = word
        if line:
            out.append(prefix + line if prefix else line)
    return out


_CACHE = {}


def char_width(text):
    """A character-count wrap: 'width' is a max character count, not points."""
    return len(text)


class Builder:
    def __init__(self):
        self.doc = pymupdf.open()
        self.pages = []
        self.y = 0
        self.page_w = 595
        self.page_h = 842
        self._new_page()

    def _new_page(self):
        self.pages.append(self.doc.new_page(width=self.page_w, height=self.page_h))
        self.y = 56

    def space(self, need):
        if self.y + need > self.page_h - 56:
            self._new_page()

    def h1(self, text, color=(0.05, 0.15, 0.35)):
        self.space(40)
        self.pages[-1].insert_text(
            (56, self.y), text, fontname=SANS, fontsize=17,
            color=color, render_mode=0)
        self.y += 20
        self.pages[-1].draw_line(
            pymupdf.Point(56, self.y), pymupdf.Point(self.page_w - 56, self.y),
            color=color, width=1)
        self.y += 16

    def h2(self, text):
        self.space(28)
        self.pages[-1].insert_text(
            (56, self.y), text, fontname=SANS, fontsize=12,
            color=(0.2, 0.2, 0.2))
        self.y += 15

    def para(self, text, size=9.5, font=MONO, color=(0, 0, 0)):
        for line in wrap(text, 84, size, font):
            self.space(size + 5)
            self.pages[-1].insert_text(
                (56, self.y), line, fontname=font, fontsize=size,
                color=color, render_mode=0)
            self.y += size + 3.5

    def code(self, text, size=8.5):
        self.space(16)
        self.pages[-1].insert_text(
            (56, self.y), "  " + text[:110], fontname=MONO, fontsize=size,
            color=(0.15, 0.15, 0.15), render_mode=0)
        self.y += size + 3

    def save(self, path):
        self.doc.set_metadata({
            "title": "Hands-On Microservices with Spring Boot and Spring Cloud - Run Guide",
            "author": "dbillion",
            "subject": "Chapter-by-chapter execution, commands, evidence and audit",
        })
        self.doc.save(str(path), deflate=True)
        return path


def render_markdown(b, md):
    """Minimal markdown renderer: headings, paragraphs, tables, code fences."""
    in_code = False
    code_buf = []
    for raw in md.split("\n"):
        line = raw.rstrip()
        if line.strip().startswith("```"):
            if in_code:
                for c in code_buf:
                    b.code(c)
                code_buf = []
                in_code = False
            else:
                in_code = True
            continue
        if in_code:
            code_buf.append(line)
            continue

        if line.startswith("# "):
            b.h1(line[2:])
        elif line.startswith("## "):
            b.h2(line[3:])
        elif line.startswith("### "):
            b.h2(line[4:])
        elif not line.strip():
            b.space(6)
        elif line.lstrip().startswith("|"):
            b.para(line, size=8.5, font=MONO)
        elif re.match(r"^\s*[-*] ", line):
            b.para(line, size=9, font=MONO)
        else:
            b.para(line)


def find_findings(ch):
    """Find a chapter's FINDINGS.md in either layout: nested (fork) or flat (local)."""
    for cand in (
        ROOT / ch / "FINDINGS" / "FINDINGS.md",
        ROOT / ch / "FINDINGS.md",
    ):
        if cand.exists():
            return cand
    return None


def main():
    b = Builder()

    # ---- title page ----
    b.space(220)
    b.pages[-1].insert_text(
        (90, b.y), "Hands-On Microservices with",
        fontname=SANS, fontsize=24, color=(0.05, 0.15, 0.35))
    b.y += 30
    b.pages[-1].insert_text(
        (90, b.y), "Spring Boot and Spring Cloud",
        fontname=SANS, fontsize=24, color=(0.05, 0.15, 0.35))
    b.y += 26
    b.pages[-1].insert_text(
        (90, b.y), "Run Guide: chapters, commands, evidence, audit",
        fontname=SANS, fontsize=13, color=(0.35, 0.35, 0.35))
    b.y += 60
    b.pages[-1].draw_line(
        pymupdf.Point(90, b.y), pymupdf.Point(b.page_w - 90, b.y),
        color=(0.05, 0.15, 0.35), width=1.4)
    b.y += 24
    for ln in [
        "Author: Oludayo Adeoye (dbillion)",
        "Repository: github.com/dbillion/Hands-On-Microservices-with-Spring-Boot-and-Spring-Cloud",
        "Executed on GitHub Codespace redesigned-guide-9j4x6q96qwjcp7p (standardLinux32gb)",
        "Toolchain: OpenJDK 11.0.25 LTS, Gradle 5.6.4, Spring Boot 2.3.2, Spring Cloud Hoxton.SR6",
        "",
        "Every 'Expected' below was written before the command ran.",
        "Every 'Actual' is pasted output from the terminal.",
        "Chapters not yet run are listed as not-run, not glossed over.",
    ]:
        b.para(ln, size=10)
    b._new_page()

    # ---- TOC ----
    b.h1("Contents")
    toc = [(c, find_findings(c) is not None) for c in CHAPTERS]
    toc.append(("PROGRESS.md", (ROOT / "PROGRESS.md").exists()))
    for name, exists in toc:
        b.para(("  [run]    " if exists else "  [not-run] ") + name,
               size=10.5, font=MONO)
    b._new_page()

    # ---- PROGRESS ----
    b.h1("PROGRESS.md - canonical state")
    progress = ROOT / "PROGRESS.md"
    if progress.exists():
        render_markdown(b, progress.read_text(errors="replace"))
    else:
        b.para("PROGRESS.md missing - the state file was not written.")
    b._new_page()

    # ---- chapters ----
    for ch in CHAPTERS:
        f = find_findings(ch)
        if f:
            render_markdown(b, f.read_text(errors="replace"))
            b._new_page()
        else:
            b.h1(ch)
            b.para(f"No FINDINGS.md for {ch}: this chapter has not been run "
                   "on the codespace yet, so there is no evidence to report.",
                   color=(0.6, 0.1, 0.1))
            b.para("")
            b._new_page()

    # ---- summary page ----
    b.h1("Audit summary")
    ran, notrun = [], []
    for ch in CHAPTERS:
        if find_findings(ch) is not None:
            ran.append(ch)
        else:
            notrun.append(ch)
    b.para(f"Chapters run with evidence: {len(ran)} of {len(CHAPTERS)} code-bearing chapters")
    b.para("Run:   " + (", ".join(ran) if ran else "none"))
    b.para("Not run: " + (", ".join(notrun) if notrun else "none"))
    b.para("")
    b.para("Chapters 01, 02 and 08 carry no code in the repository; the book states")
    b.para("code runs Chapter03-20. They are gaps in the source, not skipped work.")
    b.para("")
    b.h2("What works (verified, not assumed)")
    for ch in ran:
        b.para(f"  {ch}: see its FINDINGS.md in this guide")
    b.para("")
    b.h2("Known blockers and gaps")
    b.para("  The book's wurstmeister/kafka and wurstmeister/zookeeper images cannot")
    b.para("  be pulled on a modern Docker (v1 manifest schema removed). Substituted")
    b.para("  confluentinc/cp-kafka:5.5.0 and cp-zookeeper:5.5.0, verified by round trip.")
    b.para("")
    b.para("  Docker Compose files were never started as files; only the database")
    b.para("  containers were replicated as bare docker run, so the docker Spring")
    b.para("  profile, service-name hosts and mem_limit remain unverified.")
    b.para("")
    b.para("  In ch09, services registered with Eureka but the composite ran with the")
    b.para("  localhost profile, so resolution through the registry was not observed.")

    out = b.save(OUT)
    import os
    print(f"wrote {out} ({os.path.getsize(out)} bytes, {b.doc.page_count} pages)")
    print(f"chapters with findings: {len(ran)} | not run: {len(notrun)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
