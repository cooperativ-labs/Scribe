import Foundation
import Vocabulary

public enum ScribeVocabularyUsage {
    public static let text = """
    scribe-vocab — read and edit Scribe's custom transcription vocabulary

    The vocabulary is one always-on list of spellings transcription should get
    right: names, companies, products, jargon. It lives at
    ~/Library/Application Support/Scribe/Vocabulary/library.json and is the same
    list the Vocabulary section of Scribe's Settings window edits. Changes apply
    to transcriptions that start afterwards; existing transcripts are unchanged
    until they are transcribed again.

    Usage:
      scribe-vocab list [--json] [--all]
      scribe-vocab add <term> [--alias <heard-as>]... [--note <text>] [--pack <name>]
      scribe-vocab remove <term>
      scribe-vocab rename <term> <new spelling>
      scribe-vocab set-aliases <term> [<heard-as>...] [--clear]
      scribe-vocab import <file|-> [--replace] [--pack <name>]
      scribe-vocab export [<file>]
      scribe-vocab clear --force
      scribe-vocab packs
      scribe-vocab pack add <name>
      scribe-vocab pack enable|disable|remove <name>
      scribe-vocab revision
      scribe-vocab path

    Options:
      --alias <text>      A mishearing this term should replace. Repeatable, and
                          also accepts a comma-separated list.
      --note <text>       A note for the person maintaining the list; never sent
                          to the recognizer.
      --pack <name>       Act on a named pack instead of the personal list.
      --json              Machine-readable output (list, packs, revision).
      --all               Include packs, not only the personal list.
      --replace           Import replaces the list instead of merging into it.
      --clear             Remove every mishearing from a term.
      --force             Required by `clear`, which removes every term.
      --directory <path>  Use a vocabulary directory other than the shared one.

    Notes:
      Terms are matched case-insensitively, so `remove nvidia` removes NVIDIA.
      Adding a term that is already present merges the new mishearings into it,
      which makes `add` safe to run twice.
      Terms shorter than \(VocabularyTerm.minimumLength) characters are kept but not
      applied to transcription; `list` marks them.

    Import format (one term per line):
      # comments and blank lines are skipped
      NVIDIA
      macOS: Mac OS, Mac O S
    """
}