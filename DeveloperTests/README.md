# Private evaluation data

AlmRecorder keeps evaluation code and schemas in Git, but never ships a shared speaker dataset.
Each developer builds and loads a private local set.

The default workspace is:

`~/Library/Application Support/AlmRecorder/DeveloperEvaluation`

Set `ALMREC_EVALUATION_WORKSPACE` to use another external directory. Paths inside any Git
worktree are rejected.

## Speaker test set

1. In Settings → Evaluation, review complete conversations and mark correct conversations as
   Speaker gold. Use the pair-labeling queue for Same, Different, and Multiple speakers labels.
2. Export the reviewed data:

   ```sh
   python3 Scripts/extract_speaker_test_set.py
   ```

   The extractor opens the source database read-only and creates
   `DeveloperEvaluation/speaker-identification`. Use `--output` for a new versioned directory.
3. Run the private end-to-end benchmark:

   ```sh
   ALMREC_SPEAKER_EVAL=1 swift test \
     --filter SpeakerPipelineLiveEval/test_allSpeakerProfilesOnConfirmedSet
   ```

   Use `ALMREC_SPEAKER_TEST_SET=/absolute/external/path` to load a different developer-local set.

## Global-speaker safety shadow

Run:

```sh
DeveloperTests/run-private-speaker-shadow.sh
```

The wrapper makes a consistent temporary SQLite snapshot and runs migrations plus evaluation only
on that copy. It never opens or mutates the live application database. Set
`ALMREC_PRIVATE_LIBRARY_DB` to load a different developer's local snapshot source.

## Current production end-to-end benchmark

The preferred path is **Settings → Evaluation → Compare presets** inside AlmRecorder. The app
already owns the developer's Voice Memos security bookmark, displays progress, and saves results
locally.

For imported audio, or when the terminal has Full Disk Access, run the same production path from
the command line:

```sh
DeveloperTests/run-private-speaker-benchmark.sh
```

The default is the Balanced profile. Select several without changing app settings:

```sh
ALMREC_SPEAKER_EVAL_PROFILES=legacy,balanced,accuracy,targetedSortformer \
DeveloperTests/run-private-speaker-benchmark.sh
```

The wrapper again evaluates a disposable database snapshot. Results are saved in the external
DeveloperEvaluation workspace and include every global reconciliation candidate. macOS will block
the command-line process from protected Voice Memos audio unless that terminal has Full Disk
Access; the wrapper detects this and points the developer back to the in-app benchmark.
