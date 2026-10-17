# Provenance

Design derives from read-only investigation of Athena NSS's controller
(https://github.com/ZyPulse-zy/athena-nss-mainline), especially generation-specific
retirement, RT victim reservations, source leases and bounded recovery history.
The 2026-10-17 local delivery candidate was
`e5d1b5d85320affd6f71e04fe926b5d3272acbd60b6a925530f0377cc73893a1` (a delivery
artifact identifier, not a public Git commit).

The module is a new standalone implementation of those control principles. It
removes fixed five/six-WAN assumptions, 32-slot constants, NSS status parsing,
command paths, addresses, private device topology, service lifecycle and kernel
writes. It retains lifetime history across empty source observations, uses an
explicit lifecycle-end API, and validates restorable state with portable JSON
slot keys. There is no compatibility/deployment claim for Athena's current ABI.

Authorship: Yuen Su <zypulsecore@gmail.com>. AI assistance was used for design,
implementation, test development and documentation. GPL-2.0-only; see COPYING.
No credentials, private flow captures or production dumps are included.
