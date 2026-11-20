// SPDX-License-Identifier: GPL-3.0-or-later
// publik edition: whether the "Sign in with publik" gate still covers the window. The app's
// first-run screens wait for it, so a click on the gate cannot dismiss them unseen.
export const publikGate = $state({ open: true });
