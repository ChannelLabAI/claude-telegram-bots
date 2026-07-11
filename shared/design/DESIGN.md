# Design — ChannelLab v1.1（雙主題正式版：深藍 editorial＋對外深色 BOLD）

ChannelLab 品牌設計語言單一真相源。deck、MVP UI、對外頁一律先讀此檔；頁面服從系統，不各自發明。要改，改這份檔——不做頁面級偷改。
**v1 狀態**：老兔 2026-07-11 拍板轉正（decision dec-20260711-design-md-v0，web gate）。內容由 Agency Deck 2026 v3（17 頁，2026-07-11 過審）以 hallmark `study` 萃取＋品牌既定事實融合而成（v0 → v1 無內容變更，僅狀態轉正）。重大內容更新須再過 Reviewer 後升版。
**v1.1 草案（⚠️ 待老兔過目，勿先引用）**：文末「對外深色 BOLD 主題」起的三個段落＋禁用清單第 1/2 條的 scope 加註，
吸收老兔定版 deck `ChannelLAB-sc-dark-BOLD-laotu-final.pdf`（老兔 23:24「這個是我訂版可以對外的」）的手訂 delta；
v1 既有段落除該兩條加註外一字未動。

## System
- Genre · editorial（深藍權威 × 雜誌字階；反 AI slop：不用罐頭漸層、不居中一切、不三欄 icon grid）
- 語言 · 繁中為主、技術詞英文；標題可英文（Archivo Black 無 CJK，中文標題自動落 Noto Sans TC Black）
- Axes · paper-band: dark #0E2337（L 14%）／light #F5F0EB（L 94%）雙主題 · display-style: heavy-geometric-sans（roman，禁 italic 標題）· accent-hue: 深鋼藍 207°

## 色彩 Tokens（canonical＝deck v3 實檔 `:root`，hex 為準；hue 實測值附註）

**品牌深藍全階（單一色相 206.5–210°，嚴禁跳出此帶）**

```css
/* 深藍階梯（暗 → 亮） */
--navy-900:#0E2337;  /* hue 209° L14% · dark 主題底色 --bg */
--navy-800:#132F4A;  /* hue 210° L18% · 色塊拼貼最深階 */
--navy-750:#16324D;  /* hue 210° L19% · dark 主題面板 --bg2 */
--navy-deep:#123B5C; /* hue 207° L22% · 流體背景深部 */
--navy-700:#1B4B72;  /* hue 207° L28% · ★品牌主色（logo 同色）· light 主題 accent --ch */
--navy-500:#2E6DA0;  /* hue 207° L40% · 次 accent --ch2（雙主題同值）· 色塊最亮階 */
--navy-300:#6FA3CC;  /* hue 207° L62% · dark 主題 accent --ch */
--navy-150:#A8C6DE;  /* hue 207° L76% · 細線/ghost 編號/kicker on dark */

/* 紙面與文字 */
--paper:#F5F0EB;     /* hue 30° 暖白 L94% · light 主題底色；深底上的主文字色 */
--paper-2:#FDFBF8;   /* light 主題面板 */
--ink:#1B2A38;       /* hue 209° L16% · light 主題主文字 */
--ink-2:#4C5B69;     /* light 主題次文字 --dim */
--dim-on-dark:#BCC9D6;  --mute-on-dark:#8FA3B4;  --mute-on-light:#7A8794;

/* 線 */
--line-on-dark:rgba(168,198,222,.20);   --line-on-light:rgba(27,75,114,.20);
```

**主題語義對映**（deck v3 `html[data-theme]` 實檔）：
| 語義 | dark | light |
|---|---|---|
| --bg / --bg2 | #0E2337 / #16324D | #F5F0EB / #FDFBF8 |
| --text / --dim / --mute | #F5F0EB / #BCC9D6 / #8FA3B4 | #1B2A38 / #4C5B69 / #7A8794 |
| --ch（accent）/ --ch2 | #6FA3CC / #2E6DA0 | #1B4B72 / #2E6DA0 |

**使用紀律**：新色一律從 #1B4B72 同色相（≈207°）導出，先查上表有沒有現成階；不夠用就提案加進此檔，不准頁面內 inline 發明。

## 字體階層（deck v3 實檔 Google Fonts stack）

| 角色 | 字體 | 用法 |
|---|---|---|
| Display | `"Archivo Black","Noto Sans TC","Noto Sans SC",sans-serif` | 大標/巨數字。**一律 roman**（禁 italic 標題）。英文標題優先；中文落 Noto Black |
| Body | `"Inter","Noto Sans TC","Noto Sans SC",system-ui,sans-serif` | 內文 400–700；lead 段可 500 |
| Label / Mono | `"JetBrains Mono",monospace` | kicker、頁碼、章節號、pill、資料標籤。**大寫＋字距 .16em–.3em** |
| Editorial 旁註 | `"Noto Serif TC",Georgia,serif` italic | 僅 NOTE/引言類旁註（唯一允許 italic 之處） |

**三層字階公式**（每頁必備層次）：`kicker`（mono 小字大字距）→ `display`（Archivo 大標）→ `lead`（Inter 內文色 --dim）。尺寸用 `clamp(min, vh/vw, max)` 比例單位，禁固定 px 大標。

## 版式語彙（頁面構成的積木，全部來自 deck v3 實作）

1. **流體漸層背景**（封面/收尾/品牌時刻頁）：多層 radial-gradient 深藍絲流。配方（deck v3 `.s-cover::before` 實檔）：
   `radial-gradient(120vw 90vh at 78% -12%,#2E6DA0 0%,transparent 52%) + radial-gradient(90vw 70vh at -8% 108%,#123B5C 0%,transparent 55%) + radial-gradient(70vw 52vh at 96% 88%,rgba(111,163,204,.34) 0%,transparent 58%) + linear-gradient(152deg,#0E2337 0%,#132F4A 46%,#1B4B72 100%)`，上疊旋轉 -9° blur(14px) 的淺色霧帶。**雙主題皆深藍**（品牌時刻不隨主題變淺）。
2. **細線＋pill**：1px 漸層 rule（`linear-gradient(90deg, accent, transparent 82%)`）＋ mono 膠囊副題（半透明深藍漸層底、1px 淺線框、字距 .3em）。
3. **大編號卡**：左 2px accent 線 + ghost 大編號（Archivo、opacity .16–.18、絕對定位右上）+ 標題 + 說明。標題 box 必 shrink-to-fit（inline-block + max-width），防與 ghost 編號 box 相交。
4. **～已棄用：照片挖線條～**（2026-07-11 老兔拍板棄用）：曾兩輪嘗試（b9e6 白線疊加版、c7a3 透明鏤空版）模仿 ref-2 範例效果不到位，老兔判「棄用這個設計」。**此手法不得再用於任何 ChannelLab 產出**——未來如需照片特效，另行提案新方向並附參考對齊驗證，勿復刻此條。歷史規格見 git 歷史，不留正文。
5. **大色塊拼貼**（老兔欽點手法 B）：大面積深藍階梯色塊（`linear-gradient(165deg)` 用相鄰兩階：#132F4A→#0E2337、#1B4B72→#132F4A、#2E6DA0→#1B4B72）＋巨型 Archivo 數字＋照片/證據圖並置。**要顯眼（占半頁以上）不是點綴**；適合 KPI/案例成果/業務矩陣頁。塊內文字一律 paper 系（不隨主題）。
6. **左右分欄**（GEO Pitch Deck 基調）：內容頁 44%/56% 或 7/5 split；深藍 rail + 淺灰 main 的明暗對比構圖。
7. **明暗節奏**：封面/收尾＝深藍流體 bookend；內容頁隨主題（dark=深藍、light=紙面）；數據重點頁可整塊反差。
8. **真實資料紀律**：數字/照片/logo 一律真實資產；無數據就不畫儀表盤，無 metric 就不寫「+47%」——寧可留白。

## Logo 使用規則
- 資產：白版（深底用）＋深藍版（淺底用，logo 本體＝#1B4B72 系），現以 base64 內嵌於 deck（`.brandlogo` 規則，aspect-ratio 490/100 或 1280/266 橫式）。
- 深底（navy/流體背景）→ 白版；淺底（--paper）→ 深藍版。**禁**在深藍色塊上放深藍版、禁重繪/改色/變形。
- 尺寸兩級：hero（封面主視覺，`clamp(110px,24vh,210px)` 高）；角標（頁眉/頁腳，15–26px 高）。

## CTA / 互動 voice
- 主按鈕：accent 底（--ch）+ paper 字，radius 10–12px；次按鈕：1px 線框 ghost。
- 連結色＝該主題 accent。焦點環 `:focus-visible` 必備、不動畫。
- Motion stance：**motion-cut**（deck v3 實檔僅 theme fade 0.3s + progress bar；無 reveal 動畫、無動畫庫）。要加動畫先提案改此檔。

## 禁用清單（negative list——審稿先 grep 這區）
1. **主題間 accent 混用**——#4EA6D6 電光藍＝BOLD 對外主題 accent、#6FA3CC 系＝深藍 editorial 主題 accent，兩者皆為正色（老兔 2026-07-11 澄清：從未禁用 #4EA6D6，早前「禁模板青藍」係 Anya spec 推導過度）。走鐘的定義＝在單一頁面/主題內混用兩套 accent，或大面積填色違反電光藍功能性 accent 規則。
   （v1.1 scope 加註已由上行取代——老兔 2026-07-11 23:52 拍板解禁。）
   **對外深色 BOLD 主題的專用電光藍**（見文末 v1.1 段）——BOLD 主題內合法且唯一，跨主題混用仍禁。
2. **近黑 #0b0c0e / #111316 / #24272c 系**——v2 舊底色；深底一律用 navy-900 系。
   （v1.1 scope 加註已由上行取代——老兔 2026-07-11 23:52 拍板解禁。）
   深藍 editorial 主題內仍禁，BOLD 主題內為正色。
3. **AI 罐頭味**：紫色漸層、彩虹/多色相漸層、居中一切、三欄 icon grid、玻璃擬態濫用。
4. **emoji 當圖標**（UI/deck 一律幾何線條 glyph 或真實 logo）。
5. **假數據**：發明的 metric（+47%、10×）、假 testimonial、假合作夥伴 logo（[[NOXCAT 夥伴非真]] 教訓）。
6. **italic 標題**、italic display（serif 旁註除外）。
7. **固定 px 版式**（大標/間距必 clamp/vw/vh，防視口跑版）；SVG 線＋HTML 絕對定位雙座標系（防漂移，承技能樹 18219 教訓——線與節點必共用同一座標基準）。
8. **文字直接壓照片無遮罩**（要嘛線框語彙、要嘛深藍漸層 overlay ≥.34 opacity）。

## Provenance（hallmark study emission 規範要求）
- source_mode：url-equivalent（本地 HTML `tasks/assets/deck2026-restyle/full/channellab-deck-2026-v3.html`）＋ image 補充（同目錄 slide-01~17.png 渲染截圖，補 rhythm 盲區）
- 來源歸屬：**(a) 自有作品**——ChannelLab 自家 deck，twinkle 製作、Bella 過審、老兔 2026-07-11 拍板
- 萃取日期：2026-07-11 · 工具：hallmark v1.1.0（commit aeb42fb，anya 供應鏈審查釘版）
- 信心註記：色值/字體/結構/motion＝實檔 grep 級精度；rhythm 判讀來自渲染截圖（generous 留白、左傾編排、變化式 section 節奏）

## Notes（study 診斷指出「不要帶走」的反面）
- deck v3 本身乾淨，無 bouncy hover/transition-all/hover-scale 反模式；唯一歷史教訓＝v2 青藍 accent 與近黑底（已入禁用清單第 1、2 條）。
- hallmark 的 macrostructure 目錄是網頁導向；deck 的 DNA 以「版式語彙」（上節 8 條積木）承載，非單一 macrostructure——套用到 MVP UI/對外頁時，從積木組頁，勿硬套 slide 版型。

---

# v1.1 正式版・對外深色 BOLD 主題（老兔定版手訂，2026-07-11 23:52 拍板轉正）

> 來源＝`tasks/assets/deck2026-restyle/ChannelLAB-sc-dark-BOLD-laotu-final.pdf`（18 頁，老兔親手定版「可以對外」）。
> 全部色值/字階＝PDF 逐頁轉圖放大實測（pdftoppm 100dpi，1334×750/頁；取樣座標附後），禁憑印象。
> 定位：**對外（partners/簡中市場）專用主題**，與 v1 品牌深藍 editorial 雙主題並存，不互相取代。

## BOLD 色彩 Tokens（實測）

```css
--bold-bg:#0B0C0E;      /* 近黑底 · 全 18 頁 dominant (11,12,14) · v2 復辟,老兔手訂 */
--bold-bg2:#111316;     /* 圖表/panel 面板底 · pg09/15 次階 (17,19,22) */
--bold-card:#22252C;    /* 卡片階 · pg18 (34,37,44) */
--bold-electric:#4EA6D6;/* ★電光藍 accent · pg02 編號 stroke 取樣 box(60,255)-(120,310) n=468 + 標題底線 rule box(63,125)-(140,140) */
--bold-bone:#E8E6E1;    /* 米白 display/標題 · pg01 封面大標 box(80,320)-(690,500) n=40721 · 暖骨白非純白 */
--bold-dim:#8A8982;     /* 內文/次要字 · pg01 body + pg02 條目副題同值 */
--bold-mute:#6A6A62;    /* kicker/角標暖灰 · pg01 box(60,38)-(330,50) */
--bold-ghost:#212223;   /* 幽靈輪廓字 stroke · pg02 INDEX box(540,540)-(900,600)——僅比底亮 ~9%,若隱若現 */
```

**電光藍使用規則**（逐頁歸納 pg02/09）：只做**功能性 accent**——空心大編號 stroke、標題底線 rule、
mono kicker 前綴（§07）、圖表標籤/狀態點/pill 線框、數據高亮（24/7·AUTONOMOUS）。
**不做大面積填色、不當文字底**（定版全 18 頁無 solid 電光藍色塊）；唯一例外＝CTA 類小元件可實底＋近黑字。

## BOLD 字體與字階（實測 @1920 換算）

- 字體＝**沿用 v1 堆疊**：PDF 內嵌 ArchivoBlack-Regular 實錘；Menlo/STSongti-SC 為老兔 Mac 列印 fallback
  （非設計意圖，HTML 版仍用 JetBrains Mono／Noto Sans SC），Georgia-Italic＝旁註 voice 沿用。
- **對外語言＝簡中**（Noto Sans SC 優先於 TC）；標題英簡混排（Archivo 英文＋粗黑簡中）。
- 字階實測：封面 display 字高 ~76px/行（3 行塊 299px，行距極緊 ~0.96）；內容頁 h 字高 ~55px/行；
  空心編號字高 ~46px；幽靈輪廓字 ~245px 字高（≈340px font-size）。
- **空心編號**＝Archivo Black＋`-webkit-text-stroke`（~1.5–2px 電光藍）＋`color:transparent`——BOLD 簽名手法。

## BOLD 版式積木（新增三條，接續 v1 積木 #8）

9. **幽靈輪廓字背景層**（定版簽名，pg01「2026」/pg02「INDEX」/矩陣頁「MATRIX」等）：
   章節關鍵詞全大寫 Archivo，transparent 填色＋#212223 stroke（比底亮 ~9%），~340px 級，
   絕對定位靠邊**出血裁切**，z 在內容之下。一頁最多一詞，詞義呼應該頁章節。
10. **菱形照片頁型**（復刻課九課煉成＋定版配色，幾何公式＝`tasks/assets/deck2026-restyle/replica/GEOMETRY.md` 單一真相源）：
    照片=完整矩形場（上/下/左直邊出血＋右緣 chevron）；三重同心菱形帶（1u／貼騎導出外環＝1.7u+√2·gap）以底色刻痕疊加；
    半透明菱形 wash＋V-tip registration＋edge-riding 貼騎。BOLD 皮膚＝底/帶 #0B0C0E、wash rgba(78,166,214,.62→.82) 單色 alpha 梯、
    菱內字 #0B0C0E（dark-on-electric，同 CTA voice；wash 最淺階疊純黑照片對比下界 3.2 ≥3.0 大字 AA）、
    右欄 bone/electric/dim 三層字階＋幽靈詞。示例渲染＝`replica/diamond-page-bold.html/.png`（幾何 byte 級同 d4a6 終版）。
11. **BOLD 明暗節奏**：全冊恆近黑（無 light 頁），節奏靠「幽靈詞有無」與「圖表 panel #111316 密度」切換，
    封面/收尾用暗調實照（深色織物質感）非流體漸層——與 v1 積木 #1 的深藍絲流區隔。
12. **半規進度排**（d2c6 入庫，2026-07-12 anya gate 過）：180° 半規儀表——左水平起點、順時針過頂，
    `fill 角=pct×180°`，圓帽端頭；弧厚 0.257R、環距 3.63R、中心數字 cap 0.315R 置平邊高度
    （幾何公式=`tasks/assets/deck2026-restyle/replica/GEOMETRY.md §六`）。BOLD 皮：電光藍 #4EA6D6 值弧
    （多環同 accent，單色紀律）＋缺口 `--bold-card #22252C` 暗階（勿純灰）＋bone #E8E6E1 數字/標籤＋
    dim #8A8982 說明；下方堆疊=幾何 SVG icon（bone）→粗體標籤→說明。實檔：`replica/ring-brand.html`。
13. **交錯垂直時間軸**（d2c6 入庫，同上）：節點**等距**（節距=170.3px@1920，非內容驅動）＋交錯律
    （日期膠囊與文字塊分居中線兩側逐條互換、文字向中線對齊）；幾何=`GEOMETRY.md §七`。BOLD 皮：
    電光細中軸（2px, .85）＋近黑底電光框節點＋膠囊=電光實底＋近黑 mono 字（CTA voice 同源）＋
    暗階發射圓；標題列=mono kicker（電光）+bone 大標+電光短底線。實檔：`replica/timeline-brand.html`。

## Delta 對照表（v1 → 定版，逐項標來源頁）

| # | 項目 | v1（deck v3） | 定版（laotu-final） | 來源頁/取樣 |
|---|---|---|---|---|
| 1 | 深底 | navy-900 #0E2337 | **#0B0C0E 近黑** | 全 18 頁 dominant；panel #111316（pg09 FIG 框） |
| 2 | accent | #6FA3CC／#2E6DA0（207°） | **#4EA6D6 電光藍**（201°） | pg02 編號+底線；pg09 標籤/pill/狀態 |
| 3 | 大編號 | ghost 實字 opacity .16 | **空心 stroke 編號**（透明填＋電光藍描邊） | pg02 目錄 01–06 |
| 4 | 背景層 | 流體漸層/霧帶 | **幽靈輪廓詞**（INDEX/2026 等，#212223 stroke 出血） | pg01「2026」、pg02「INDEX」 |
| 5 | 對外語言 | 繁中為主 | **簡中**（Songti 為列印 fallback，意圖=Noto SC） | 全冊；pg01 副標 |
| 6 | display 色 | paper #F5F0EB | **bone #E8E6E1**（更暖 2 階） | pg01 大標 n=40721 |
| 7 | 封面質感 | 深藍流體漸層 | **暗調實照**（深色織物） | pg01 背景 |
| 8 | 禁用清單 #1/#2 | 封殺 #4EA6D6/#0B0C0E | **BOLD 主題內回歸為正色**（scope 化） | 本表 #1/#2 推論，⚠️ 最需老兔確認 |

## Exports
本檔 hex 即 canonical。要 tokens.css / Tailwind @theme / DTCG tokens.json 輸出格式，另開任務擴充（v1 之後）。
