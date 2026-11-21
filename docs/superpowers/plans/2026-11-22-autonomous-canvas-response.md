# Restore the autonomous canvas response

The Linear project requires pen-up to produce an AI annotation and question on the canvas. The existing automatic mode schedules observations but stops at a proposal-review button. That approval step does not satisfy the recorded MVP acceptance condition.

Use the existing explicit connection/automatic-mode consent. After a current, validated, sufficiently confident automatic response, apply its proposal through the same annotation-only storage boundary used by manual approval. Keep manual questions as reviewable proposals. Preserve cancellation, revision/epoch/target checks, sensitivity filtering, deduplication, undo, layer visibility and student-ink isolation. Keep the response available for recognition history without offering an already applied proposal again.

The live regression should write native PencilKit ink into an empty note, invoke the real assistant's pen-up scheduling, receive actual BAZE HTTPS/SSE responses, and prove marks appear without an approval call. Replace 5 with 4 through the student-edit path and prove the assistant's contextual follow-up and restored records. Collect progress phases and screenshots. Restore test connection settings afterwards.

- [ ] Reproduce the missing automatic application with the native live regression.
- [ ] Apply current automatic replies and update proposal UI and consent text.
- [ ] Run the native regression batch and inspect actual output.
- [ ] Reconcile Linear and verification documentation with the demonstrated behavior.

Do not claim physical Pencil latency or battery coverage from the simulator. Do not repeat the 60-image benchmark for this app-side scheduling change.
