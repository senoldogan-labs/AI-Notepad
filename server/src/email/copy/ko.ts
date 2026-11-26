import type { EmailCopy, FreePlanFacts, TrialFacts } from "./types";

export const ko: EmailCopy = {
  htmlLang: "ko",
  footer: {
    lifecycleReason: "Gistsmith 팁과 알림을 요청하셔서 이 메일을 보내드립니다.",
    unsubscribe: "수신 거부",
    inApp: "또는 Gistsmith › 설정 › 계정에서 끌 수 있습니다.",
    confirmReason:
      "누군가 이 주소를 Gistsmith에 입력했습니다. 본인이 아니라면 이 메일을 무시하세요. 링크를 누르지 않으면 더 이상 보내지 않으며, 주소는 7일 안에 삭제합니다.",
    notMe: "제가 아닙니다",
    privacy: (address: string): string => `개인정보 문의: ${address}`,
    privacyPolicy: "개인정보 처리방침",
    country: "핀란드",
    reply: "궁금한 점이 있으면 이 메일에 답장하세요.",
    linkFallback: "버튼이 작동하지 않으면 이 링크를 여세요:",
  },
  confirm: {
    subject: "Gistsmith 이메일 주소를 확인하세요",
    preheader: "한 번만 누르면 Gistsmith 팁과 체험 알림을 받습니다.",
    heading: "이메일 주소 확인",
    body: [
      "무료 체험이 끝나기 전에 Gistsmith의 몇 가지 팁과 알림을 받겠다고 요청하셨습니다.",
      "이 주소를 확인하면 시작합니다. 다른 메일은 보내지 않으며 언제든 그만둘 수 있습니다.",
    ],
    cta: "이메일 주소 확인",
    note: "링크는 7일 동안 유효합니다.",
  },
  welcome: {
    subject: "Gistsmith와 함께하는 첫 회의",
    preheader: "회의를 녹음하면 끝날 때 노트를 받습니다.",
    heading: "Gistsmith에 오신 것을 환영합니다",
    body: [
      "Gistsmith가 하는 일을 가장 빨리 보는 방법은 실제 회의 한 번입니다. 다음 통화가 시작되면 Mac의 Gistsmith에서 녹음 시작을 클릭하거나, iPhone에서 Gistsmith를 열고 녹음 시작을 탭하세요.",
      "회의가 끝나면 녹취록, 짧은 노트, 할 일을 받습니다.",
      "iPhone에서는 Gistsmith 키보드로 어떤 앱에서든 음성으로 입력할 수 있습니다. 무료이며, Gistsmith › 설정 › 키보드에서 켜세요.",
    ],
    cta: "회의 녹음하기",
  },
  activation: {
    subject: "첫 회의를 시작할 준비가 되셨나요?",
    preheader: "무료 체험은 첫 회의부터 시작됩니다.",
    heading: "체험이 아직 시작되지 않았습니다",
    body: (trial: TrialFacts): readonly string[] => [
      `Gistsmith에 가입하셨지만 아직 회의를 녹음하지 않으셨습니다. 괜찮습니다. 무료 체험(회의 ${trial.meetings}회 또는 ${trial.days}일)은 첫 회의부터 시작됩니다.`,
      "다음 Zoom, Teams, Google Meet 통화나 대면 회의에서 Gistsmith 녹음을 시작하세요. 회의가 끝나면 노트가 준비됩니다.",
      "이와 관련해 보내드리는 알림은 이번이 유일합니다.",
    ],
    cta: "회의 녹음하기",
  },
  trialEnding: {
    subject: "Gistsmith 체험이 곧 끝납니다",
    preheader: "이후 회의와 노트는 이렇게 됩니다.",
    heading: "체험이 곧 끝납니다",
    oneMeetingLeft: "무료 체험 회의가 1회 남았습니다.",
    endsWithinDay: "무료 체험이 하루 안에 끝납니다.",
    nextFree: (free: FreePlanFacts): string =>
      `그 후 계정은 자동으로 무료 요금제로 바뀝니다. 매월 AI 노트 ${free.notesPerMonth}개(${free.maxMeetingMinutes}분 이하 회의)와 매월 질문하기 답변 ${free.asksPerMonth}개를 쓸 수 있습니다.`,
    nextSubscribe: "그 후에도 Gistsmith가 회의를 받아쓰고 노트를 작성하려면 구독이 필요합니다.",
    keep: "어느 경우든 회의와 노트는 기기에 남습니다.",
    cta: "요금제 보기",
  },
  freePlan: {
    subject: "Gistsmith 무료 요금제로 바뀌었습니다",
    preheader: "무료 요금제에 매월 포함되는 것.",
    heading: "무료 요금제에 오신 것을 환영합니다",
    intro: "체험이 끝나 계정이 이제 무료 요금제입니다. 만료되지 않습니다.",
    items: (free: FreePlanFacts): readonly string[] => [
      `매월 AI 노트 ${free.notesPerMonth}개, ${free.maxMeetingMinutes}분 이하 회의`,
      `매월 질문하기 답변 ${free.asksPerMonth}개`,
      "기기에서 작성되는 녹취록",
      "iPhone의 Gistsmith 키보드",
    ],
    outro: "더 긴 회의나 더 많은 노트가 필요하면 Personal과 Pro로 한도를 높일 수 있습니다.",
    cta: "요금제 비교",
  },
};
