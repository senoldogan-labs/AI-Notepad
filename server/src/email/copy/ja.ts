import type { EmailCopy, FreePlanFacts, TrialFacts } from "./types";

export const ja: EmailCopy = {
  htmlLang: "ja",
  footer: {
    lifecycleReason: "Gistsmith のヒントとリマインダーを希望されたため、このメールをお送りしています。",
    unsubscribe: "配信を停止",
    inApp: "または Gistsmith › 設定 › アカウントでオフにできます。",
    confirmReason:
      "どなたかがこのアドレスを Gistsmith に入力しました。お心当たりがない場合は、このメールを無視してください。リンクがクリックされない限りこれ以上は送信されず、アドレスは 7 日以内に削除されます。",
    notMe: "身に覚えがない",
    privacy: (address: string): string => `プライバシーに関するお問い合わせ: ${address}`,
    privacyPolicy: "プライバシーポリシー",
    country: "フィンランド",
    reply: "ご質問はこのメールに返信してください。",
    linkFallback: "ボタンが使えない場合は、こちらのリンクを開いてください:",
  },
  confirm: {
    subject: "Gistsmith のメールアドレスを確認してください",
    preheader: "ワンクリックで、Gistsmith のヒントとお試し期間のリマインダーが届きます。",
    heading: "メールアドレスの確認",
    body: [
      "Gistsmith からのいくつかのヒントと、無料お試し期間が終わる前のリマインダーをご希望いただきました。",
      "このアドレスを確認すると配信が始まります。それ以外のメールは送らず、いつでも停止できます。",
    ],
    cta: "メールアドレスを確認",
    note: "リンクの有効期限は 7 日間です。",
  },
  welcome: {
    subject: "Gistsmith で最初のミーティングを",
    preheader: "ミーティングを録音すると、終了時にノートが届きます。",
    heading: "Gistsmith へようこそ",
    body: [
      "Gistsmith の働きを知るいちばんの近道は、実際のミーティングです。次の通話が始まったら、Mac の Gistsmith で「録音を開始」をクリックするか、iPhone で Gistsmith を開いて「録音を開始」をタップしてください。",
      "ミーティングが終わると、文字起こし、短いノート、やることリストが届きます。",
      "iPhone では、Gistsmithキーボードを使ってどのアプリでも音声で入力できます。無料です。Gistsmith › 設定 › キーボードでオンにしてください。",
    ],
    cta: "ミーティングを録音",
  },
  activation: {
    subject: "最初のミーティングの準備はできましたか?",
    preheader: "無料お試し期間は最初のミーティングから始まります。",
    heading: "お試し期間はまだ始まっていません",
    body: (trial: TrialFacts): readonly string[] => [
      `Gistsmith に登録されましたが、まだミーティングを録音していません。ご安心ください。無料お試し期間(${trial.meetings} 回のミーティングまたは ${trial.days} 日間)は最初のミーティングから始まります。`,
      "次の Zoom、Teams、Google Meet の通話や対面のミーティングで、Gistsmith の録音を始めてください。ミーティングが終わるとノートができあがります。",
      "このご案内をお送りするのは今回だけです。",
    ],
    cta: "ミーティングを録音",
  },
  trialEnding: {
    subject: "Gistsmith のお試し期間がまもなく終わります",
    preheader: "このあとミーティングとノートがどうなるか。",
    heading: "お試し期間がまもなく終わります",
    oneMeetingLeft: "無料お試しのミーティングは残り 1 回です。",
    endsWithinDay: "無料お試し期間は 1 日以内に終わります。",
    nextFree: (free: FreePlanFacts): string =>
      `その後、アカウントは自動的に無料プランに移ります。毎月 ${free.notesPerMonth} 件の AI ノート(${free.maxMeetingMinutes} 分までのミーティング)と、毎月 ${free.asksPerMonth} 件の質問への回答が使えます。`,
    nextSubscribe: "その後も Gistsmith でミーティングの文字起こしとノート作成を続けるには、サブスクリプションが必要です。",
    keep: "いずれの場合も、ミーティングとノートはお使いのデバイスに残ります。",
    cta: "プランを見る",
  },
  freePlan: {
    subject: "Gistsmith 無料プランになりました",
    preheader: "無料プランで毎月使えるもの。",
    heading: "無料プランへようこそ",
    intro: "お試し期間が終わり、アカウントは無料プランになりました。期限はありません。",
    items: (free: FreePlanFacts): readonly string[] => [
      `毎月 ${free.notesPerMonth} 件の AI ノート(${free.maxMeetingMinutes} 分までのミーティング)`,
      `毎月 ${free.asksPerMonth} 件の質問への回答`,
      "デバイス上で作成される文字起こし",
      "iPhone の Gistsmithキーボード",
    ],
    outro: "より長いミーティングやより多くのノートが必要になったら、Personal と Pro で上限が上がります。",
    cta: "プランを比較",
  },
};
