// SPDX-FileCopyrightText: 2026 Keephaven LLC
// SPDX-License-Identifier: AGPL-3.0-only
//
// Its own module, outside launcher/windows/, on purpose. The helper's derivation takes
// launcher/windows as its src, so a file added in there changes the helper's store path and
// every image built after it - for code the helper does not even compile. The writer never
// goes on a drive, so it has no business in that tree.
module keephaven.co/writer

go 1.22
