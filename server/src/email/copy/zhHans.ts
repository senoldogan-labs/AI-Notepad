import type { EmailCopy, FreePlanFacts, TrialFacts } from "./types";

export const zhHans: EmailCopy = {
  htmlLang: "zh-Hans",
  footer: {
    lifecycleReason: "你收到这封邮件，是因为你订阅了 Gistsmith 的使用提示和提醒。",
    unsubscribe: "退订",
    inApp: "也可以在 Gistsmith › 设置 › 账户中关闭。",
    confirmReason:
      "有人在 Gistsmith 中填写了这个地址。如果不是你，请忽略这封邮件：不点击链接就不会再收到任何邮件，我们会在 7 天内删除该地址。",
    notMe: "不是我本人",
    privacy: (address: string): string => `隐私问题：${address}`,
    privacyPolicy: "隐私政策",
    country: "芬兰",
    reply: "有问题？直接回复这封邮件。",
    linkFallback: "如果按钮无法使用，请打开这个链接：",
  },
  confirm: {
    subject: "确认你在 Gistsmith 的邮箱",
    preheader: "点击一次，即可收到 Gistsmith 使用提示和试用提醒。",
    heading: "确认你的邮箱",
    body: [
      "你希望 Gistsmith 给你发送一些使用提示，并在免费试用结束前提醒你。",
      "确认这个地址后我们就开始发送。我们不会发送其他内容，你也可以随时停止。",
    ],
    cta: "确认我的邮箱",
    note: "链接 7 天内有效。",
  },
  welcome: {
    subject: "用 Gistsmith 记录你的第一场会议",
    preheader: "录制一场会议，结束时即可收到笔记。",
    heading: "欢迎使用 Gistsmith",
    body: [
      "了解 Gistsmith 最快的方法，就是录一场真实的会议。下次通话开始时，在 Mac 上的 Gistsmith 中点按“开始录制”，或在 iPhone 上打开 Gistsmith 并轻点“开始录制”。",
      "会议结束后，你会收到文字稿、一份简短笔记和待办事项。",
      "在 iPhone 上，Gistsmith 键盘让你在任何 App 中用语音输入。它是免费的：在 Gistsmith › 设置 › 键盘中开启。",
    ],
    cta: "录制会议",
  },
  activation: {
    subject: "准备好你的第一场会议了吗？",
    preheader: "免费试用从你的第一场会议开始计算。",
    heading: "你的试用尚未开始",
    body: (trial: TrialFacts): readonly string[] => [
      `你已经注册了 Gistsmith，但还没有录制会议。没关系：免费试用（${trial.meetings} 场会议或 ${trial.days} 天）从你的第一场会议才开始计算。`,
      "下次参加 Zoom、Teams、Google Meet 通话或线下会议时，在 Gistsmith 中开始录制。会议结束时笔记就准备好了。",
      "关于这件事，我们只提醒这一次。",
    ],
    cta: "录制会议",
  },
  trialEnding: {
    subject: "你的 Gistsmith 试用即将结束",
    preheader: "之后你的会议和笔记会怎样。",
    heading: "试用即将结束",
    oneMeetingLeft: "你还剩 1 场免费试用会议。",
    endsWithinDay: "你的免费试用将在一天内结束。",
    nextFree: (free: FreePlanFacts): string =>
      `之后，你的账户会自动转为免费方案：每月 ${free.notesPerMonth} 份 AI 笔记（适用于 ${free.maxMeetingMinutes} 分钟以内的会议），以及每月 ${free.asksPerMonth} 次提问回答。`,
    nextSubscribe: "之后，需要订阅才能让 Gistsmith 继续转写你的会议并撰写笔记。",
    keep: "无论哪种情况，你的会议和笔记都会保留在你的设备上。",
    cta: "查看方案",
  },
  freePlan: {
    subject: "你已转为 Gistsmith 免费方案",
    preheader: "免费方案每月包含的内容。",
    heading: "欢迎使用免费方案",
    intro: "你的试用已结束，账户现已转为免费方案。它不会过期。",
    items: (free: FreePlanFacts): readonly string[] => [
      `每月 ${free.notesPerMonth} 份 AI 笔记，适用于 ${free.maxMeetingMinutes} 分钟以内的会议`,
      `每月 ${free.asksPerMonth} 次提问回答`,
      "在你的设备上生成的文字稿",
      "iPhone 上的 Gistsmith 键盘",
    ],
    outro: "需要更长的会议或更多笔记时，Personal 和 Pro 会提高上限。",
    cta: "比较方案",
  },
};
