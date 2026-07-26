# Repository privacy boundary

AlmRecorder's source repository must never contain user-derived material.

The following are local data and are never repository assets:

- media or database files;
- transcript, utterance, summary, note, or export content;
- speaker, attendee, calendar, filename, or contact identity data;
- human labels, gold sets, review actions, evaluation corpora, or fixtures;
- benchmark, comparison, diagnostic, or evaluation results derived from a user's library;
- tests or examples copied, adapted, paraphrased, or reconstructed from user material.

Evaluation code operates on the current user's local database. Each user creates and owns their own
labels and gold set on their machine. Generated inputs and results stay under the app's Application
Support directory or an ignored local evaluation directory.

The standalone `AlmRecorderEvaluationKit` module defines provider contracts, versioned envelopes,
external-workspace validation, and JSON artifact storage. It contains no default provider data.
`ALMREC_EVALUATION_WORKSPACE` may select a developer-specific external workspace; repository paths
and paths nested in any Git worktree are rejected.

The public repository intentionally excludes test/evaluation source trees and local extraction
utilities. Product source may define algorithms, schemas, generic UI copy, and protocol contracts,
but it must not embed realistic utterance fixtures or person-specific examples.

Before committing, run:

```bash
./Scripts/check_repository_privacy.sh
```

Before publishing a repository or release, run the history form from the intended publication
root:

```bash
./Scripts/check_repository_privacy.sh --history
```

The check blocks tracked corpus-like paths and formats, machine-specific home paths, email literals,
and any exact fingerprints in the ignored `.privacy-blocklist`. Put one literal per line in that
local file; never commit the blocklist itself.

If private data reaches any remote, removing it in a later commit is not sufficient. Contain the
repository, rotate affected credentials if applicable, rewrite or replace all published history,
and request server-side cache and object removal from the host.
