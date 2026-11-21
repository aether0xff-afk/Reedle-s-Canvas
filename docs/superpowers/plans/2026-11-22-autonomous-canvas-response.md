# Restore the autonomous canvas response

The Linear project requires pen-up to produce an AI annotation and question on the canvas. The existing automatic mode schedules observations but stops at a proposal-review button. That approval step does not satisfy the recorded MVP acceptance condition.

Use the existing explicit connection/automatic-mode consent. After a current, validated, sufficiently confident automatic response, apply its proposal through the same annotation-only storage boundary used by manual approval. Keep manual questions as reviewable proposals. Preserve cancellation, revision/epoch/target checks, sensitivity filtering, deduplication, undo, layer visibility and student-ink isolation. Keep the response available for recognition history without offering an already applied proposal again.

The live regression should write native PencilKit ink into an empty note, invoke the real assistant's pen-up scheduling, receive actual BAZE HTTPS/SSE responses, and prove marks appear without an approval call. Replace 5 with 4 through the student-edit path and prove the assistant's contextual follow-up and restored records. Collect progress phases and screenshots. Restore test connection settings afterwards.

- [x] Reproduce the missing automatic application with the native live regression.
- [x] Apply current automatic replies and update proposal UI and consent text.
- [ ] Run the native regression batch and inspect actual output.
- [ ] Reconcile Linear and verification documentation with the demonstrated behavior.

Do not claim physical Pencil latency or battery coverage from the simulator. Do not repeat the 60-image benchmark for this app-side scheduling change.

The red native run 44921024274 completed 74 cases with exactly one failure: automatic pen-up returned valid circle/question actions, but zero annotations were present instead of two. All other cases passed. Its runner cleanup completed and its encrypted delivery packet was removed.

BAZE-served Codex reviewed the patch with its provider credential absent from the child environment and authentication supplied by the encrypted-store helper. The review identified that a local application failure could discard the response after dirty-region acknowledgement. Retain the validated response as a pending proposal before attempting automatic storage, and report a local save error without imposing network backoff. Stale proposals are dismissed.

Review scope ruling: this project has no released automatic-suggestion contract to migrate, and the user's recorded requirement explicitly calls for automatic canvas reactions. Keep the existing default manual mode, document the automatic toggle's behavior in the connection editor, and honor the user's existing authorization rather than adding another permission prompt.
