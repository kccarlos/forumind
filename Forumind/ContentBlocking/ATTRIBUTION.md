# Content blocking rules — attribution

The `ads-*.json` and `privacy-*.json` files in this directory are **derived
from** the following filter lists, written by **The EasyList authors**
(<https://easylist.to/>):

- **EasyList** — <https://easylist.to/easylist/easylist.txt> (list version 202609260507, last modified 26 Sep 2026 05:07 UTC)
- **EasyPrivacy** — <https://easylist.to/easylist/easyprivacy.txt> (list version 202609260507, last modified 26 Sep 2026 05:07 UTC)

EasyList and EasyPrivacy are dual-licensed under GPLv3 and the Creative Commons
Attribution-ShareAlike 3.0 Unported license; this app uses them under
**CC BY-SA 3.0** (<https://creativecommons.org/licenses/by-sa/3.0/>). See
<https://easylist.to/pages/licence.html>.

**Changes made:** the filters were mechanically converted from Adblock Plus
syntax to WebKit content-blocker JSON, filters WebKit cannot express were
omitted, and the result was split into several files. These converted files are
a derivative work and are shared under the same license, **CC BY-SA 3.0**.

The conversion tooling (source) is at <https://github.com/kccarlos/forumind/tree/main/scripts/adblock>; it uses
Brave's adblock-rust (MPL-2.0) at build time only.
