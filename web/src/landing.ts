const REPO_URL = "https://github.com/steventsao/byot";
const APP_STORE_URL = "https://apps.apple.com/us/app/byot/id6782403920";

// Official Apple badge artwork, inlined so the page has zero external requests.
const APP_STORE_BADGE = `<svg xmlns="http://www.w3.org/2000/svg" width="119.66407" height="40" viewBox="0 0 119.66407 40"> <title>Download_on_the_App_Store_Badge_US-UK_RGB_blk_4SVG_092917</title> <g> <g> <g> <path d="M110.13477,0H9.53468c-.3667,0-.729,0-1.09473.002-.30615.002-.60986.00781-.91895.0127A13.21476,13.21476,0,0,0,5.5171.19141a6.66509,6.66509,0,0,0-1.90088.627A6.43779,6.43779,0,0,0,1.99757,1.99707,6.25844,6.25844,0,0,0,.81935,3.61816a6.60119,6.60119,0,0,0-.625,1.90332,12.993,12.993,0,0,0-.1792,2.002C.00587,7.83008.00489,8.1377,0,8.44434V31.5586c.00489.3105.00587.6113.01515.9219a12.99232,12.99232,0,0,0,.1792,2.0019,6.58756,6.58756,0,0,0,.625,1.9043A6.20778,6.20778,0,0,0,1.99757,38.001a6.27445,6.27445,0,0,0,1.61865,1.1787,6.70082,6.70082,0,0,0,1.90088.6308,13.45514,13.45514,0,0,0,2.0039.1768c.30909.0068.6128.0107.91895.0107C8.80567,40,9.168,40,9.53468,40H110.13477c.3594,0,.7246,0,1.084-.002.3047,0,.6172-.0039.9219-.0107a13.279,13.279,0,0,0,2-.1768,6.80432,6.80432,0,0,0,1.9082-.6308,6.27742,6.27742,0,0,0,1.6172-1.1787,6.39482,6.39482,0,0,0,1.1816-1.6143,6.60413,6.60413,0,0,0,.6191-1.9043,13.50643,13.50643,0,0,0,.1856-2.0019c.0039-.3106.0039-.6114.0039-.9219.0078-.3633.0078-.7246.0078-1.0938V9.53613c0-.36621,0-.72949-.0078-1.09179,0-.30664,0-.61426-.0039-.9209a13.5071,13.5071,0,0,0-.1856-2.002,6.6177,6.6177,0,0,0-.6191-1.90332,6.46619,6.46619,0,0,0-2.7988-2.7998,6.76754,6.76754,0,0,0-1.9082-.627,13.04394,13.04394,0,0,0-2-.17676c-.3047-.00488-.6172-.01074-.9219-.01269-.3594-.002-.7246-.002-1.084-.002Z" style="fill: #a6a6a6"/> <path d="M8.44483,39.125c-.30468,0-.602-.0039-.90429-.0107a12.68714,12.68714,0,0,1-1.86914-.1631,5.88381,5.88381,0,0,1-1.65674-.5479,5.40573,5.40573,0,0,1-1.397-1.0166,5.32082,5.32082,0,0,1-1.02051-1.3965,5.72186,5.72186,0,0,1-.543-1.6572,12.41351,12.41351,0,0,1-.1665-1.875c-.00634-.2109-.01464-.9131-.01464-.9131V8.44434S.88185,7.75293.8877,7.5498a12.37039,12.37039,0,0,1,.16553-1.87207,5.7555,5.7555,0,0,1,.54346-1.6621A5.37349,5.37349,0,0,1,2.61183,2.61768,5.56543,5.56543,0,0,1,4.01417,1.59521a5.82309,5.82309,0,0,1,1.65332-.54394A12.58589,12.58589,0,0,1,7.543.88721L8.44532.875H111.21387l.9131.0127a12.38493,12.38493,0,0,1,1.8584.16259,5.93833,5.93833,0,0,1,1.6709.54785,5.59374,5.59374,0,0,1,2.415,2.41993,5.76267,5.76267,0,0,1,.5352,1.64892,12.995,12.995,0,0,1,.1738,1.88721c.0029.2832.0029.5874.0029.89014.0079.375.0079.73193.0079,1.09179V30.4648c0,.3633,0,.7178-.0079,1.0752,0,.3252,0,.6231-.0039.9297a12.73126,12.73126,0,0,1-.1709,1.8535,5.739,5.739,0,0,1-.54,1.67,5.48029,5.48029,0,0,1-1.0156,1.3857,5.4129,5.4129,0,0,1-1.3994,1.0225,5.86168,5.86168,0,0,1-1.668.5498,12.54218,12.54218,0,0,1-1.8692.1631c-.2929.0068-.5996.0107-.8974.0107l-1.084.002Z"/> </g> <g id="_Group_" data-name="&lt;Group&gt;"> <g id="_Group_2" data-name="&lt;Group&gt;"> <g id="_Group_3" data-name="&lt;Group&gt;"> <path id="_Path_" data-name="&lt;Path&gt;" d="M24.76888,20.30068a4.94881,4.94881,0,0,1,2.35656-4.15206,5.06566,5.06566,0,0,0-3.99116-2.15768c-1.67924-.17626-3.30719,1.00483-4.1629,1.00483-.87227,0-2.18977-.98733-3.6085-.95814a5.31529,5.31529,0,0,0-4.47292,2.72787c-1.934,3.34842-.49141,8.26947,1.3612,10.97608.9269,1.32535,2.01018,2.8058,3.42763,2.7533,1.38706-.05753,1.9051-.88448,3.5794-.88448,1.65876,0,2.14479.88448,3.591.8511,1.48838-.02416,2.42613-1.33124,3.32051-2.66914a10.962,10.962,0,0,0,1.51842-3.09251A4.78205,4.78205,0,0,1,24.76888,20.30068Z" style="fill: #fff"/> <path id="_Path_2" data-name="&lt;Path&gt;" d="M22.03725,12.21089a4.87248,4.87248,0,0,0,1.11452-3.49062,4.95746,4.95746,0,0,0-3.20758,1.65961,4.63634,4.63634,0,0,0-1.14371,3.36139A4.09905,4.09905,0,0,0,22.03725,12.21089Z" style="fill: #fff"/> </g> </g> <g> <path d="M42.30227,27.13965h-4.7334l-1.13672,3.35645H34.42727l4.4834-12.418h2.083l4.4834,12.418H43.438ZM38.0591,25.59082h3.752l-1.84961-5.44727h-.05176Z" style="fill: #fff"/> <path d="M55.15969,25.96973c0,2.81348-1.50586,4.62109-3.77832,4.62109a3.0693,3.0693,0,0,1-2.84863-1.584h-.043v4.48438h-1.8584V21.44238H48.4302v1.50586h.03418a3.21162,3.21162,0,0,1,2.88281-1.60059C53.645,21.34766,55.15969,23.16406,55.15969,25.96973Zm-1.91016,0c0-1.833-.94727-3.03809-2.39258-3.03809-1.41992,0-2.375,1.23047-2.375,3.03809,0,1.82422.95508,3.0459,2.375,3.0459C52.30227,29.01563,53.24953,27.81934,53.24953,25.96973Z" style="fill: #fff"/> <path d="M65.12453,25.96973c0,2.81348-1.50586,4.62109-3.77832,4.62109a3.0693,3.0693,0,0,1-2.84863-1.584h-.043v4.48438h-1.8584V21.44238H58.395v1.50586h.03418A3.21162,3.21162,0,0,1,61.312,21.34766C63.60988,21.34766,65.12453,23.16406,65.12453,25.96973Zm-1.91016,0c0-1.833-.94727-3.03809-2.39258-3.03809-1.41992,0-2.375,1.23047-2.375,3.03809,0,1.82422.95508,3.0459,2.375,3.0459C62.26711,29.01563,63.21438,27.81934,63.21438,25.96973Z" style="fill: #fff"/> <path d="M71.71047,27.03613c.1377,1.23145,1.334,2.04,2.96875,2.04,1.56641,0,2.69336-.80859,2.69336-1.91895,0-.96387-.67969-1.541-2.28906-1.93652l-1.60937-.3877c-2.28027-.55078-3.33887-1.61719-3.33887-3.34766,0-2.14258,1.86719-3.61426,4.51855-3.61426,2.624,0,4.42285,1.47168,4.4834,3.61426h-1.876c-.1123-1.23926-1.13672-1.9873-2.63379-1.9873s-2.52148.75684-2.52148,1.8584c0,.87793.6543,1.39453,2.25488,1.79l1.36816.33594c2.54785.60254,3.60645,1.626,3.60645,3.44238,0,2.32324-1.85059,3.77832-4.79395,3.77832-2.75391,0-4.61328-1.4209-4.7334-3.667Z" style="fill: #fff"/> <path d="M83.34621,19.2998v2.14258h1.72168v1.47168H83.34621v4.99121c0,.77539.34473,1.13672,1.10156,1.13672a5.80752,5.80752,0,0,0,.61133-.043v1.46289a5.10351,5.10351,0,0,1-1.03223.08594c-1.833,0-2.54785-.68848-2.54785-2.44434V22.91406H80.16262V21.44238H81.479V19.2998Z" style="fill: #fff"/> <path d="M86.065,25.96973c0-2.84863,1.67773-4.63867,4.29395-4.63867,2.625,0,4.29492,1.79,4.29492,4.63867,0,2.85645-1.66113,4.63867-4.29492,4.63867C87.72609,30.6084,86.065,28.82617,86.065,25.96973Zm6.69531,0c0-1.9541-.89551-3.10742-2.40137-3.10742s-2.40039,1.16211-2.40039,3.10742c0,1.96191.89453,3.10645,2.40039,3.10645S92.76027,27.93164,92.76027,25.96973Z" style="fill: #fff"/> <path d="M96.18606,21.44238h1.77246v1.541h.043a2.1594,2.1594,0,0,1,2.17773-1.63574,2.86616,2.86616,0,0,1,.63672.06934v1.73828a2.59794,2.59794,0,0,0-.835-.1123,1.87264,1.87264,0,0,0-1.93652,2.083v5.37012h-1.8584Z" style="fill: #fff"/> <path d="M109.3843,27.83691c-.25,1.64355-1.85059,2.77148-3.89844,2.77148-2.63379,0-4.26855-1.76465-4.26855-4.5957,0-2.83984,1.64355-4.68164,4.19043-4.68164,2.50488,0,4.08008,1.7207,4.08008,4.46582v.63672h-6.39453v.1123a2.358,2.358,0,0,0,2.43555,2.56445,2.04834,2.04834,0,0,0,2.09082-1.27344Zm-6.28223-2.70215h4.52637a2.1773,2.1773,0,0,0-2.2207-2.29785A2.292,2.292,0,0,0,103.10207,25.13477Z" style="fill: #fff"/> </g> </g> </g> <g id="_Group_4" data-name="&lt;Group&gt;"> <g> <path d="M37.82619,8.731a2.63964,2.63964,0,0,1,2.80762,2.96484c0,1.90625-1.03027,3.002-2.80762,3.002H35.67092V8.731Zm-1.22852,5.123h1.125a1.87588,1.87588,0,0,0,1.96777-2.146,1.881,1.881,0,0,0-1.96777-2.13379h-1.125Z" style="fill: #fff"/> <path d="M41.68068,12.44434a2.13323,2.13323,0,1,1,4.24707,0,2.13358,2.13358,0,1,1-4.24707,0Zm3.333,0c0-.97607-.43848-1.54687-1.208-1.54687-.77246,0-1.207.5708-1.207,1.54688,0,.98389.43457,1.55029,1.207,1.55029C44.57522,13.99463,45.01369,13.42432,45.01369,12.44434Z" style="fill: #fff"/> <path d="M51.57326,14.69775h-.92187l-.93066-3.31641h-.07031l-.92676,3.31641h-.91309l-1.24121-4.50293h.90137l.80664,3.436h.06641l.92578-3.436h.85254l.92578,3.436h.07031l.80273-3.436h.88867Z" style="fill: #fff"/> <path d="M53.85354,10.19482H54.709v.71533h.06641a1.348,1.348,0,0,1,1.34375-.80225,1.46456,1.46456,0,0,1,1.55859,1.6748v2.915h-.88867V12.00586c0-.72363-.31445-1.0835-.97168-1.0835a1.03294,1.03294,0,0,0-1.0752,1.14111v2.63428h-.88867Z" style="fill: #fff"/> <path d="M59.09377,8.437h.88867v6.26074h-.88867Z" style="fill: #fff"/> <path d="M61.21779,12.44434a2.13346,2.13346,0,1,1,4.24756,0,2.1338,2.1338,0,1,1-4.24756,0Zm3.333,0c0-.97607-.43848-1.54687-1.208-1.54687-.77246,0-1.207.5708-1.207,1.54688,0,.98389.43457,1.55029,1.207,1.55029C64.11232,13.99463,64.5508,13.42432,64.5508,12.44434Z" style="fill: #fff"/> <path d="M66.4009,13.42432c0-.81055.60352-1.27783,1.6748-1.34424l1.21973-.07031v-.38867c0-.47559-.31445-.74414-.92187-.74414-.49609,0-.83984.18213-.93848.50049h-.86035c.09082-.77344.81836-1.26953,1.83984-1.26953,1.12891,0,1.76563.562,1.76563,1.51318v3.07666h-.85547v-.63281h-.07031a1.515,1.515,0,0,1-1.35254.707A1.36026,1.36026,0,0,1,66.4009,13.42432Zm2.89453-.38477v-.37646l-1.09961.07031c-.62012.0415-.90137.25244-.90137.64941,0,.40527.35156.64111.835.64111A1.0615,1.0615,0,0,0,69.29543,13.03955Z" style="fill: #fff"/> <path d="M71.34816,12.44434c0-1.42285.73145-2.32422,1.86914-2.32422a1.484,1.484,0,0,1,1.38086.79h.06641V8.437h.88867v6.26074h-.85156v-.71143h-.07031a1.56284,1.56284,0,0,1-1.41406.78564C72.0718,14.772,71.34816,13.87061,71.34816,12.44434Zm.918,0c0,.95508.4502,1.52979,1.20313,1.52979.749,0,1.21191-.583,1.21191-1.52588,0-.93848-.46777-1.52979-1.21191-1.52979C72.72121,10.91846,72.26613,11.49707,72.26613,12.44434Z" style="fill: #fff"/> <path d="M79.23,12.44434a2.13323,2.13323,0,1,1,4.24707,0,2.13358,2.13358,0,1,1-4.24707,0Zm3.333,0c0-.97607-.43848-1.54687-1.208-1.54687-.77246,0-1.207.5708-1.207,1.54688,0,.98389.43457,1.55029,1.207,1.55029C82.12453,13.99463,82.563,13.42432,82.563,12.44434Z" style="fill: #fff"/> <path d="M84.66945,10.19482h.85547v.71533h.06641a1.348,1.348,0,0,1,1.34375-.80225,1.46456,1.46456,0,0,1,1.55859,1.6748v2.915H87.605V12.00586c0-.72363-.31445-1.0835-.97168-1.0835a1.03294,1.03294,0,0,0-1.0752,1.14111v2.63428h-.88867Z" style="fill: #fff"/> <path d="M93.51516,9.07373v1.1416h.97559v.74854h-.97559V13.2793c0,.47168.19434.67822.63672.67822a2.96657,2.96657,0,0,0,.33887-.02051v.74023a2.9155,2.9155,0,0,1-.4834.04541c-.98828,0-1.38184-.34766-1.38184-1.21582v-2.543h-.71484v-.74854h.71484V9.07373Z" style="fill: #fff"/> <path d="M95.70461,8.437h.88086v2.48145h.07031a1.3856,1.3856,0,0,1,1.373-.80664,1.48339,1.48339,0,0,1,1.55078,1.67871v2.90723H98.69v-2.688c0-.71924-.335-1.0835-.96289-1.0835a1.05194,1.05194,0,0,0-1.13379,1.1416v2.62988h-.88867Z" style="fill: #fff"/> <path d="M104.76125,13.48193a1.828,1.828,0,0,1-1.95117,1.30273A2.04531,2.04531,0,0,1,100.73,12.46045a2.07685,2.07685,0,0,1,2.07617-2.35254c1.25293,0,2.00879.856,2.00879,2.27V12.688h-3.17969v.0498a1.1902,1.1902,0,0,0,1.19922,1.29,1.07934,1.07934,0,0,0,1.07129-.5459Zm-3.126-1.45117h2.27441a1.08647,1.08647,0,0,0-1.1084-1.1665A1.15162,1.15162,0,0,0,101.63527,12.03076Z" style="fill: #fff"/> </g> </g> </g> </svg>`;

export function renderLanding(): string {
  return `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>BYOT &mdash; a native iOS client for OpenCode</title>
  <meta name="description" content="BYOT is a native iOS client for OpenCode, the open-source coding agent. Connect to the OpenCode server running on your own computer and drive real coding sessions from your iPhone. No account, no relay, no tracking.">
  <link rel="canonical" href="https://byot.app/">
  <meta name="apple-itunes-app" content="app-id=6782403920">
  <meta property="og:type" content="website">
  <meta property="og:title" content="BYOT — a native iOS client for OpenCode">
  <meta property="og:description" content="Your machine does the work. Your phone drives it. No account, no relay, no tracking.">
  <meta property="og:url" content="https://byot.app/">
  <style>
    :root {
      color-scheme: light;
      --paper: #f4f5f1;
      --ink: #1c1f1a;
      --muted: #5d665c;
      --line: #d9ded3;
      --card: #ffffff;
      /* semantic color lives only inside the phone */
      --add: #1f7a3d;
      --del: #b3382e;
      --perm: #9a6a00;
      --net: #0f766e;
      --screen: #f2f2f7;
      --sans: ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
      --mono: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
      --section-space: clamp(56px, 8vw, 88px);
    }
    * { box-sizing: border-box; }
    html { scroll-behavior: smooth; scroll-padding-top: 24px; scrollbar-color: var(--muted) var(--paper); }
    body {
      margin: 0;
      background: var(--paper);
      color: var(--ink);
      font: 16px/1.55 var(--sans);
      -webkit-font-smoothing: antialiased;
    }
    ::selection { background: var(--ink); color: var(--paper); }
    a { color: inherit; text-underline-offset: 0.2em; }
    a:focus-visible, button:focus-visible {
      outline: 2px solid var(--ink);
      outline-offset: 5px;
      border-radius: 4px;
    }
    .wrap { max-width: 1020px; margin: 0 auto; padding: 0 24px; }
    .skip-link {
      position: absolute; z-index: 1; left: 24px; top: 8px;
      padding: 12px 16px; background: var(--ink); color: var(--paper);
      transform: translateY(-160%);
    }
    .skip-link:focus { transform: none; }
    main:focus { outline: none; }

    /* header */
    header .wrap {
      display: flex; align-items: center; justify-content: space-between; gap: 20px;
      padding-top: 16px; padding-bottom: 8px;
    }
    .wordmark {
      display: inline-flex; align-items: center; min-height: 44px;
      font: 600 18px var(--mono);
      text-decoration: none;
      letter-spacing: -0.01em;
    }
    .wordmark::after {
      content: "";
      display: inline-block;
      width: 0.55em; height: 1em;
      background: var(--ink);
      margin-left: 3px;
      vertical-align: text-bottom;
    }
    .nav { display: flex; flex-wrap: wrap; gap: 20px; }
    .nav a { display: inline-flex; align-items: center; min-height: 44px; font-size: 14px; color: var(--muted); text-decoration: none; }
    .nav a:hover { color: var(--ink); text-decoration: underline; }

    /* type system */
    h1 {
      font-size: clamp(44px, 6.2vw, 64px);
      font-weight: 700;
      letter-spacing: -0.035em;
      line-height: 1.03;
      margin: 0 0 20px;
    }
    h1 span { display: block; }
    h1 .quiet { color: var(--muted); }
    h2 {
      font-size: clamp(24px, 3.4vw, 30px);
      font-weight: 650;
      letter-spacing: -0.025em;
      line-height: 1.15;
      margin: 0 0 12px;
      text-wrap: balance;
    }
    .hero-summary { max-width: 26ch; font-size: 22px; font-weight: 500; line-height: 1.4; margin: 0 0 16px; text-wrap: pretty; }
    .hero-summary span { display: block; }
    .lede { color: var(--muted); font-size: 17px; max-width: 46ch; margin: 0 0 28px; }
    section { padding: var(--section-space) 0 0; }
    .sectionhead { max-width: 620px; margin-bottom: 36px; }
    .sectionhead p { color: var(--muted); margin: 0; }

    /* hero */
    .hero .wrap {
      display: grid;
      grid-template-columns: 1.05fr 0.95fr;
      gap: 56px;
      align-items: center;
      padding-top: 28px;
    }
    .cta-row { display: flex; flex-wrap: wrap; align-items: center; gap: 14px; }
    .store { display: inline-block; line-height: 0; }
    .store svg { height: 56px; width: auto; display: block; }
    .store:hover { opacity: 0.82; }
    .store:active, .ghbtn:active { transform: translateY(1px); }
    .ghbtn {
      display: inline-flex; align-items: center;
      height: 56px; padding: 0 22px;
      border: 1.5px solid var(--ink); border-radius: 12px;
      font: 600 15px var(--sans);
      color: var(--ink); text-decoration: none;
    }
    .ghbtn:hover { background: var(--ink); color: var(--paper); }
    .trustline {
      display: flex; flex-wrap: wrap; gap: 6px 14px;
      padding: 0; list-style: none;
      font: 13px/1.5 var(--sans);
      color: var(--muted);
      margin: 18px 0 0;
    }
    .trustline li { white-space: nowrap; }
    .trustline li + li::before { content: ""; display: inline-block; width: 3px; height: 3px; margin-right: 10px; margin-bottom: 3px; border-radius: 50%; background: currentColor; }

    /* phone */
    .phonecol { display: grid; justify-items: center; gap: 16px; margin: 0; min-width: 0; }
    .phone {
      width: min(300px, 100%);
      background: #0c0d0c;
      border-radius: 46px;
      padding: 10px;
      box-shadow: 0 24px 60px rgba(28, 31, 26, 0.18), 0 2px 8px rgba(28, 31, 26, 0.12);
    }
    .screen {
      background: var(--screen);
      border-radius: 37px;
      overflow: hidden;
      display: flex;
      flex-direction: column;
      aspect-ratio: 9 / 19.5;
    }
    .topbar {
      display: grid;
      grid-template-columns: 1fr auto 1fr;
      align-items: center;
      padding: 10px 20px 2px;
      font: 600 12px var(--mono);
    }
    .island { width: 88px; height: 25px; background: #0c0d0c; border-radius: 14px; }
    .net { justify-self: end; color: var(--net); font: 500 10px var(--mono); }
    .sessionbar {
      display: flex; justify-content: space-between; align-items: center; gap: 8px;
      padding: 10px 14px;
      border-bottom: 1px solid #e2e2e7;
      font: 500 12px var(--sans);
    }
    .sessionbar .chip {
      font: 500 10px var(--mono);
      color: var(--muted);
      background: #e9e9ee;
      border-radius: 99px;
      padding: 3px 8px;
      white-space: nowrap;
    }
    .feed {
      display: flex; flex-direction: column; gap: 8px;
      padding: 12px 12px 14px;
      font-size: 12.5px;
      flex: 1;
      min-height: 0;
      overflow: hidden;
    }
    .composer {
      display: flex; align-items: center; gap: 8px;
      padding: 6px 12px 4px;
    }
    .cinput {
      flex: 1;
      background: var(--card);
      border-radius: 18px;
      padding: 8px 14px;
      font-size: 12.5px;
      color: var(--muted);
    }
    .csend {
      width: 30px; height: 30px;
      border-radius: 99px;
      background: var(--ink);
      color: #fff;
      display: grid; place-items: center;
      font-size: 15px; font-weight: 600;
    }
    .homebar {
      width: 110px; height: 4px;
      border-radius: 99px;
      background: #0c0d0c;
      opacity: 0.3;
      margin: 6px auto 8px;
    }
    @media (prefers-reduced-motion: reduce) {
      html { scroll-behavior: auto; }
    }
    .msg-user {
      align-self: flex-end;
      max-width: 86%;
      background: var(--ink);
      color: #fff;
      border-radius: 16px 16px 4px 16px;
      padding: 8px 12px;
      line-height: 1.4;
    }
    .reasoning { font: 11px var(--mono); color: var(--muted); padding: 0 4px; }
    .tool {
      display: flex; align-items: baseline; gap: 6px;
      background: var(--card);
      border-radius: 10px;
      padding: 8px;
    }
    .tool .tname { font-weight: 600; font-size: 11.5px; white-space: nowrap; }
    .tool .targ {
      font: 10.5px var(--mono);
      color: var(--muted);
      overflow: hidden; text-overflow: ellipsis; white-space: nowrap;
      flex: 1; min-width: 0;
    }
    .tool .tstat { font: 600 10px var(--mono); color: var(--add); white-space: nowrap; }
    .tool .tdiff { font: 600 10px var(--mono); white-space: nowrap; }
    .tdiff .plus { color: var(--add); }
    .tdiff .minus { color: var(--del); }
    .perm {
      background: var(--card);
      border: 1px solid var(--line);
      border-radius: 10px;
      padding: 9px 10px 10px;
    }
    .perm .ptitle { font: 600 10px var(--mono); text-transform: uppercase; letter-spacing: 0.08em; color: var(--perm); margin-bottom: 2px; }
    .perm .pfile { font: 11px var(--mono); color: var(--ink); margin-bottom: 8px; }
    .perm .pbtns { display: flex; gap: 6px; }
    .perm .pbtn {
      font: 500 10.5px var(--sans);
      border: 1px solid #d9d9de;
      border-radius: 99px;
      padding: 4px 8px;
      background: transparent;
      color: var(--ink);
      white-space: nowrap;
    }
    .perm .pbtn.fill { background: var(--ink); border-color: var(--ink); color: #fff; }
    .doneline { font: 600 11px var(--mono); color: var(--add); padding: 2px 4px 0; }
    .queuedline { font: 11px var(--mono); color: var(--muted); padding: 0 4px; }
    .phonecaption { font-size: 13px; color: var(--muted); text-align: center; max-width: 300px; margin: 0; }

    /* direct line */
    .linkline {
      display: flex; align-items: center; gap: 14px;
      margin: 34px 0 26px;
    }
    .endpoint { font: 600 13px var(--mono); white-space: nowrap; }
    .rail { flex: 1; position: relative; border-top: 1.5px solid var(--ink); }
    .rail::before, .rail::after {
      content: "";
      position: absolute;
      top: -5px;
      width: 8px; height: 8px;
      border-radius: 99px;
      background: var(--ink);
    }
    .rail::before { left: -2px; }
    .rail::after { right: -2px; }
    .raillabel {
      position: absolute;
      top: -26px; left: 50%;
      transform: translateX(-50%);
      font: 11px var(--mono);
      color: var(--muted);
      white-space: nowrap;
    }
    .direct p { color: var(--muted); max-width: 70ch; margin: 0; }
    @media (max-width: 560px) {
      .linkline { flex-direction: column; align-items: flex-start; gap: 10px; margin-top: 26px; }
      .rail { flex: none; width: 0; height: 56px; border-top: 0; border-left: 1.5px solid var(--ink); margin-left: 4px; }
      .rail::before { left: -5px; top: -2px; }
      .rail::after { left: -5px; top: auto; bottom: -2px; }
      .raillabel { top: 50%; left: 18px; transform: translateY(-50%); }
    }

    /* features */
    .grid {
      display: grid;
      grid-template-columns: 1fr 1fr;
      column-gap: 48px;
    }
    .feat {
      border-top: 1px solid var(--line);
      padding: 20px 0 26px;
    }
    .feat dt { font: 600 17px/1.4 var(--sans); margin: 0 0 8px; }
    .feat dd { margin: 0; color: var(--muted); font-size: 15px; }
    dl { margin: 0; }

    /* trust rows */
    .trust { display: grid; gap: 0; max-width: 760px; }
    .trow {
      display: grid;
      grid-template-columns: 132px 1fr;
      gap: 18px;
      border-top: 1px solid var(--line);
      padding: 18px 0;
    }
    .trow .tkey { font: 600 15px/1.55 var(--sans); }
    .trow p { margin: 0; color: var(--muted); font-size: 15px; }

    /* steps */
    .steps { margin: 0; padding: 0 0 0 0; list-style: none; counter-reset: step; max-width: 640px; }
    .steps li {
      counter-increment: step;
      display: grid;
      grid-template-columns: 40px 1fr;
      gap: 14px;
      border-top: 1px solid var(--line);
      padding: 18px 0;
      color: var(--muted);
      font-size: 15px;
    }
    .steps li::before {
      content: counter(step, decimal-leading-zero);
      font: 600 12px var(--mono);
      color: var(--ink);
      padding-top: 3px;
    }
    code {
      background: var(--card);
      border: 1px solid var(--line);
      border-radius: 5px;
      padding: 1px 6px;
      font: 0.9em var(--mono);
      color: var(--ink);
    }
    .textlink { color: var(--ink); font-weight: 500; }
    .setup-help { margin: 18px 0 0; }
    .setup-help a { display: inline-flex; align-items: center; min-height: 44px; }

    /* closing cta */
    .cta-band {
      border-top: 1px solid var(--line);
      margin-top: var(--section-space);
      padding: 72px 0;
      text-align: center;
    }
    .cta-band h2 { margin-bottom: 6px; }
    .cta-band p { color: var(--muted); margin: 0 0 26px; font-size: 15px; }
    .cta-band .store { margin: 0 auto; }

    /* footer */
    footer {
      border-top: 1px solid var(--line);
      padding: 28px 0 56px;
      font-size: 13px;
      color: var(--muted);
    }
    footer .links { display: flex; flex-wrap: wrap; gap: 8px 24px; margin-bottom: 16px; }
    footer .links a { display: inline-flex; align-items: center; min-height: 44px; }
    footer a { color: var(--muted); }
    footer .fineprint { max-width: 68ch; margin: 0; }

    @media (max-width: 880px) {
      .hero .wrap { grid-template-columns: 1fr; gap: 44px; padding-top: 40px; }
      .hero-summary { max-width: 32ch; }
      .lede { max-width: 60ch; }
    }
    @media (max-width: 560px) {
      .wrap { padding-left: 20px; padding-right: 20px; }
      header .wrap { gap: 16px; }
      .nav { gap: 16px; }
      .hero .wrap { padding-top: 28px; gap: 36px; }
      .hero-summary { font-size: 20px; }
      .lede { font-size: 16px; }
      .cta-row { gap: 12px; }
      .trustline { max-width: 300px; }
      .store svg { height: 48px; }
      .ghbtn { height: 48px; padding: 0 16px; font-size: 14px; border-radius: 10px; }
      .phone { width: min(300px, 100%); }
      .grid { grid-template-columns: 1fr; }
      .trow { grid-template-columns: 1fr; gap: 6px; }
      .sectionhead { margin-bottom: 28px; }
      .cta-band { padding: 48px 0; }
    }
    @media (max-width: 360px) {
      .nav { gap: 12px; }
      .nav a { font-size: 13px; }
      .ghbtn { padding: 0 8px; }
    }
  </style>
</head>
<body>
  <a class="skip-link" href="#main">Skip to content</a>
  <header>
    <div class="wrap">
      <a class="wordmark" href="/">byot</a>
      <nav class="nav" aria-label="Main navigation">
        <a href="#setup">Set up</a>
        <a href="${REPO_URL}">GitHub</a>
        <a href="/support">Support</a>
      </nav>
    </div>
  </header>

  <main id="main" tabindex="-1">
    <div class="hero">
      <div class="wrap">
        <div>
          <h1><span>OpenCode</span><span class="quiet">iOS client</span></h1>
          <p class="hero-summary"><span>Your machine does the work.</span><span>Your phone drives it.</span></p>
          <p class="lede">BYOT connects to the OpenCode server on your own computer and lets you drive real coding sessions from your iPhone &mdash; the full turn stream, live: text, reasoning, patches, and every tool call.</p>
          <div class="cta-row">
            <a class="store" href="${APP_STORE_URL}" aria-label="Download BYOT on the App Store">${APP_STORE_BADGE}</a>
            <a class="ghbtn" href="${REPO_URL}">View on GitHub</a>
          </div>
          <ul class="trustline" aria-label="About BYOT"><li>Free</li><li>Open source</li><li>No account</li><li>No relay</li><li>No tracking</li></ul>
        </div>
        <figure class="phonecol">
          <div class="phone" aria-hidden="true">
            <div class="screen">
              <div class="topbar"><span>9:41</span><span class="island"></span><span class="net">&#9679; tailnet</span></div>
              <div class="sessionbar"><span>fix flaky upload retry</span><span class="chip">your model</span></div>
              <div class="feed">
                <div class="msg-user">the upload retry test is flaky &mdash; find and fix it</div>
                <div class="reasoning">reasoning &middot; 6s</div>
                <div class="tool"><span class="tname">Search files</span><span class="targ">pattern: "retry"</span><span class="tstat">done</span></div>
                <div class="tool"><span class="tname">Shell command</span><span class="targ">bun test upload</span><span class="tstat">done</span></div>
                <div class="perm">
                  <div class="ptitle">Permission &middot; edit</div>
                  <div class="pfile">tests/upload.test.ts</div>
                  <div class="pbtns"><span class="pbtn">Reject</span><span class="pbtn fill">Allow once</span><span class="pbtn">Always allow</span></div>
                </div>
                <div class="tool"><span class="tname">Edit</span><span class="targ">tests/upload.test.ts</span><span class="tdiff"><span class="plus">+14</span> <span class="minus">&minus;3</span></span></div>
                <div class="doneline">&#10003; turn complete &middot; 1 file changed</div>
                <div class="queuedline">&#8594; queued: "now run the full suite"</div>
              </div>
              <div class="composer"><span class="cinput">Prompt&hellip;</span><span class="csend">&#8593;</span></div>
              <div class="homebar"></div>
            </div>
          </div>
          <figcaption class="phonecaption">Example session: stream, tools, permissions, diff.</figcaption>
        </figure>
      </div>
    </div>

    <section class="direct">
      <div class="wrap">
        <h2>A straight line to your server</h2>
        <div class="linkline" role="img" aria-label="Your iPhone connects directly to your Mac over HTTPS on your tailnet, with nothing in between.">
          <span class="endpoint">your iPhone</span>
          <span class="rail"><span class="raillabel">HTTPS over your tailnet</span></span>
          <span class="endpoint">your Mac</span>
        </div>
        <p>There is nothing in between. No account, no sign-up, no relay, and no BYOT servers &mdash; prompts, transcripts, and diffs travel only between your phone and the machine you already trust. Your server password lives in the iOS Keychain and is sent to that server alone.</p>
      </div>
    </section>

    <section>
      <div class="wrap">
        <div class="sectionhead">
          <h2>The whole session, in your hand</h2>
        </div>
        <dl class="grid">
          <div class="feat"><dt>live stream</dt><dd>Watch turns as they happen: assistant text, reasoning, files, patches, and every tool call with its input, progress, output, and errors.</dd></div>
          <div class="feat"><dt>permissions</dt><dd>Every ask becomes a card you can answer &mdash; allow once, always allow, or reject. Questions take choices or your own text.</dd></div>
          <div class="feat"><dt>your models</dt><dd>Pick the model per prompt, straight from your server's own catalog. Every connected provider is there &mdash; nothing hidden, nothing rewritten.</dd></div>
          <div class="feat"><dt>diffs</dt><dd>Review the session diff on your phone before you trust the result.</dd></div>
          <div class="feat"><dt>queue &amp; steer</dt><dd>Queue follow-up prompts while a turn runs, or steer the current one. Follow-ups pause, resume, and requeue cleanly if delivery fails.</dd></div>
          <div class="feat"><dt>every server</dt><dd>Add each machine you run. One combined session list across all your servers, with per-server connection health.</dd></div>
        </dl>
      </div>
    </section>

    <section>
      <div class="wrap">
        <div class="sectionhead">
          <h2>Boring where it counts</h2>
        </div>
        <div class="trust">
          <div class="trow"><span class="tkey">handshake</span><p>BYOT probes your server's health and capabilities before it connects, and degrades gracefully when versions drift. Verified against OpenCode 1.18.</p></div>
          <div class="trow"><span class="tkey">framing</span><p>A byte-level SSE parser with hard line and record caps keeps the live stream intact &mdash; including the events convenience APIs drop.</p></div>
          <div class="trow"><span class="tkey">reconcile</span><p>If the stream falls behind or disconnects, BYOT reloads state from your server instead of guessing. What your phone shows is what your machine has &mdash; sessions never wedge on a stale "working&hellip;".</p></div>
          <div class="trow"><span class="tkey">https only</span><p>The app refuses plain HTTP and never attaches credentials to an insecure request. Passwords stay in the iOS Keychain.</p></div>
        </div>
      </div>
    </section>

    <section id="setup">
      <div class="wrap">
        <div class="sectionhead">
          <h2>Bring your own server</h2>
        </div>
        <ol class="steps">
          <li><span>Run OpenCode on your machine &mdash; <code>opencode serve</code> behind HTTPS with Basic auth.</span></li>
          <li><span>Make it reachable from your phone. <code>tailscale serve</code> is the usual path; any valid TLS endpoint works.</span></li>
        </ol>
        <p class="setup-help"><a class="textlink" href="/support">Connection help &amp; troubleshooting</a></p>
      </div>
    </section>

    <div class="cta-band">
      <div class="wrap">
        <h2>Free on the App Store</h2>
        <p>iPhone and iPad &middot; requires an OpenCode server you operate</p>
        <a class="store" href="${APP_STORE_URL}" aria-label="Download BYOT on the App Store">${APP_STORE_BADGE}</a>
      </div>
    </div>
  </main>

  <footer>
    <div class="wrap">
      <div class="links">
        <a href="/privacy">Privacy</a>
        <a href="/support">Support</a>
        <a href="${REPO_URL}">GitHub</a>
        <a href="${APP_STORE_URL}">App Store</a>
      </div>
      <p class="fineprint">BYOT is developed in the open. It's a client and nothing more &mdash; no accounts, no cloud, no backend. The app talks only to OpenCode servers you configure.</p>
    </div>
  </footer>
</body>
</html>`;
}
