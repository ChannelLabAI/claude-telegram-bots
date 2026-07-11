# Design — ChannelLab（v1 正式版）

ChannelLab 品牌設計語言單一真相源。deck、MVP UI、對外頁一律先讀此檔；頁面服從系統，不各自發明。要改，改這份檔——不做頁面級偷改。
**v1 狀態**：老兔 2026-07-11 拍板轉正（decision dec-20260711-design-md-v0，web gate）。內容由 Agency Deck 2026 v3（17 頁，2026-07-11 過審）以 hallmark `study` 萃取＋品牌既定事實融合而成（v0 → v1 無內容變更，僅狀態轉正）。重大內容更新須再過 Reviewer 後升版。

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
1. **模板青藍 #4EA6D6 系**（hue 201° 高亮高飽和 cyan 傾向）——v2 舊 accent，已全數收斂為 #6FA3CC；任何高飽和 cyan（hue 185–204° 且 sat>50%）視同走鐘。
2. **近黑 #0b0c0e / #111316 / #24272c 系**——v2 舊底色；深底一律用 navy-900 系。
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

## Exports
本檔 hex 即 canonical。要 tokens.css / Tailwind @theme / DTCG tokens.json 輸出格式，另開任務擴充（v1 之後）。
