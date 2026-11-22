# Match circle actions to elliptical outlines

The final rendering comparison found that `circle` actions used a rounded rectangle. Restore the named ellipse primitive while protecting all corners of the original target. Use radii at least sqrt(2) times the target half-size plus two points of clearance, retaining the existing eleven-point minimum margin. Keep collision and region checks. Place subsequent labels outside an existing circle around the same target.

- [x] Reproduce inadequate ellipse clearance on a 280x100 target: all four expanded corners scored 1.611 instead of at most 1 in the ellipse equation.
- [x] Render with Path(ellipseIn:) and compute a safe enclosing frame.
- [x] Verify the circle and following question both fit without overlap and student bytes remain unchanged; all 14 focused core cases passed.
- [ ] Complete the full native/live/UI batch and inspect the real ellipse and restoration images.
- [ ] Record final source artifacts and preserve physical-device limits.

Screen and PDF use the same renderer. No font, model action authority or original-ink storage change is required. Server setup also now defaults to the actually verified api.baze.co deployment; a request-destination regression first observed the older default, then all 66 server cases passed after the fix.

The BAZE-served review identified that an arrow pointing into its own target's circle was blocked by that circle's bounding box. Adding the arrow to the regression reproduced the missing third mark. Exclude only the same target's circle from arrow-route obstacles, while retaining it for label placement and keeping every other student/AI obstacle. The arrow tip still uses the existing clearance outside the original target.
