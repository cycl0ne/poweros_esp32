#!/bin/sh
# SPDX-License-Identifier: MPL-2.0
# Fetch what tools/emojigen makes the emoji list and its names from
# (LOCALE:Emoji): Unicode's emoji-test.txt - every emoji, in groups and
# in order - and the CLDR's annotations, an emoji's name and keywords in
# each language the disk has. Pinned versions, each file checked against
# its sha256. Nothing of it is committed: it lands in
# toolchain/emoji/<version>, where the build looks for it.
set -eu
emoji=16.0
cldr=release-46
root=$(cd "$(dirname "$0")/.." && pwd)
out="$root/toolchain/emoji/$emoji"
mkdir -p "$out/annotations" "$out/annotationsDerived"
cd "$out"
curl -sSfL -o emoji-test.txt "https://www.unicode.org/Public/emoji/$emoji/emoji-test.txt"
curl -sSfL -o LICENSE "https://raw.githubusercontent.com/unicode-org/cldr/$cldr/LICENSE"
# A language's file, and the one it takes what it leaves out from
# (pt_PT from pt).
for code in da de en es fr hi it ja ko nl no pt pt_PT sv zh zh_Hant; do
    for kind in annotations annotationsDerived; do
        curl -sSfL -o "$kind/$code.xml" "https://raw.githubusercontent.com/unicode-org/cldr/$cldr/common/$kind/$code.xml"
    done
done
sha256sum -c --quiet <<EOF
24f0c534e86cf142e2496953e8f0e46a3e702392911eddcd29c6cced85139697  emoji-test.txt
743308f92225393665b0722b73418b4d4061fd2163e8e9c38b3368904acf19d6  LICENSE
4e59b94927065125f6b3e36efb77d270af32a0e730ea7d6c23f87436e8c8669f  annotations/da.xml
4cf875e5487f8d542d1c8634edd3a83d3020f15fa7c9d64d98c7b0e265edbb67  annotations/de.xml
7d491f1782480d50ee953d3943e8a65eacaa4394b41af9e9f89c9be418256ade  annotations/en.xml
baeb76f846321d3838a93bf63126ea52a35240987f555c6cd87651a01f734955  annotations/es.xml
03a8f16c52ef592eb77d56bf9407bb166837cf3ba9d87e53f59e0a963e00bbd9  annotations/fr.xml
701d9852d6da790bde58c1373ef458d9bc197bc17ae3480c4193be6e6d80a065  annotations/hi.xml
08c7220fb41c122ac7ea6583012e53a1538a1acb545dfcbe6d2b4f83493f3c81  annotations/it.xml
ba0fc62bf90b7ab33b47593825aee3745cfabdcee3d6d322cef89100c409ca1e  annotations/ja.xml
980d0553497008997e1dc830893d738364131a6e4255ad7f016ee2a8418e9c72  annotations/ko.xml
4775217aa854c0a43faf95db74462d7111d4269c4ed519888493ecee8fbdcda7  annotations/nl.xml
02e4f13b5c0ae8068fb201807e2b6419ad695f68bec9f274b61da9788cff8b4e  annotations/no.xml
ed7799c6e0216cec235f745ca94d63004bc201d22f6470f8f4e47cfbe2a0b8fc  annotations/pt_PT.xml
84b5dbbd6d25857d7b0d593ebd936af2e8df26404a65000918ffcca0ab3a5a70  annotations/pt.xml
0de2392699f34252945b132cb492686942bc8488bf4d7bc5cb7d40d6c2a8efe0  annotations/sv.xml
2d7ee90b147b127b1e42214784892cc98cdd4a7a294ebb1f37bdf00489c4ba6b  annotations/zh_Hant.xml
487e16c5e64b6ac1cb38a91b5f2dc25349ded224bcd78ec1f14a92bba3ef3147  annotations/zh.xml
bee54bdb32f5b2e2e79fb04afb60fbff621efbf2650fee7a7e14203d7edfd90e  annotationsDerived/da.xml
1476a74a3d3cfc8880d92b96ac086863a4e37f0a64f695c862a582fa5dbaef2f  annotationsDerived/de.xml
461d1578079c5ebc947e506df6b5a55c93f006160e8dff3f05dcf917ce081604  annotationsDerived/en.xml
1779e3aa00cbc56533dc218b735643acf27967c9f4ab6ee58d0a349d9745019c  annotationsDerived/es.xml
42af059617558844564c232116f9c06a7878028259dc171233e4a167d021f7cf  annotationsDerived/fr.xml
71c76255e641392b4a5cb01731e98aaa9577e489c971ca665a7e139547cd2c0d  annotationsDerived/hi.xml
1f4e7808261c372524aef50d6ebe6174d869d82ec8afccaf8dae91f9f3e49458  annotationsDerived/it.xml
7349579fd7bd3f09a2a62d06ba2a270b88df78d58f834cc87e9fd373f89c4ae1  annotationsDerived/ja.xml
77ed67a9e0f53a2656e318775c96318ea52b35da9e9a5cadbcd9d20719721303  annotationsDerived/ko.xml
51fc9d9860fe1a710f6274910d4024f8cca45f81b4ccbb9ce4f6711bc5e2cd42  annotationsDerived/nl.xml
78486f2ce33d401eb819f774e2e4674dac825960fabf5aa07338e7aa007d0907  annotationsDerived/no.xml
b734c1dc275d546e3e11ddf26a2cb7090620f533fd89755060782e70f6434ba6  annotationsDerived/pt_PT.xml
2e3913174d9f6a3ef210b1e95a592281e5f367bcdbdd434a5ae334cca2780252  annotationsDerived/pt.xml
a8bf35f091fbb56a0812a7d1513eec53dfee01ba922fc23f6f69798cc2d17418  annotationsDerived/sv.xml
406b93a2b61d4161fc356931a1321f3301fcc07aecda9ad4221cb4137ffb2caa  annotationsDerived/zh_Hant.xml
01d48d98a8612f779c17707db51f2ba2c55292d6c690f8a0828dd748c042206a  annotationsDerived/zh.xml
EOF
echo "Emoji $emoji and CLDR $cldr annotations in $out"
