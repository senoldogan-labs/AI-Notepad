import type { EmailCopy, FreePlanFacts, TrialFacts } from "./types";

export const ptBR: EmailCopy = {
  htmlLang: "pt-BR",
  footer: {
    lifecycleReason: "Você está recebendo isto porque pediu dicas e lembretes do Gistsmith.",
    unsubscribe: "Cancelar inscrição",
    inApp: "ou desative em Gistsmith › Ajustes › Conta.",
    confirmReason:
      "Alguém digitou este endereço no Gistsmith. Se não foi você, ignore este e-mail: nada mais é enviado sem um clique no link, e apagamos o endereço em até 7 dias.",
    notMe: "Não fui eu",
    privacy: (address: string): string => `Dúvidas sobre privacidade: ${address}`,
    privacyPolicy: "Política de privacidade",
    country: "Finlândia",
    reply: "Dúvidas? Responda a este e-mail.",
    linkFallback: "Se o botão não funcionar, abra este link:",
  },
  confirm: {
    subject: "Confirme seu e-mail para o Gistsmith",
    preheader: "Um clique para receber dicas do Gistsmith e o lembrete do seu teste.",
    heading: "Confirme seu e-mail",
    body: [
      "Você pediu ao Gistsmith algumas dicas e um lembrete antes do fim do seu teste gratuito.",
      "Confirme este endereço e começamos. Não enviamos mais nada, e você pode parar quando quiser.",
    ],
    cta: "Confirmar meu e-mail",
    note: "O link vale por 7 dias.",
  },
  welcome: {
    subject: "Sua primeira reunião com o Gistsmith",
    preheader: "Grave uma reunião e receba a nota quando ela terminar.",
    heading: "Boas-vindas ao Gistsmith",
    body: [
      "O jeito mais rápido de ver o que o Gistsmith faz é uma reunião de verdade. Quando a próxima chamada começar, clique em Iniciar gravação no Gistsmith no Mac, ou abra o Gistsmith no iPhone e toque em Iniciar gravação.",
      "Quando a reunião terminar, você recebe a transcrição, uma nota curta e as tarefas.",
      "No iPhone, o Teclado Gistsmith permite digitar por voz em qualquer app. É gratuito: ative em Gistsmith › Ajustes › Teclado.",
    ],
    cta: "Gravar uma reunião",
  },
  activation: {
    subject: "Pronto para sua primeira reunião?",
    preheader: "Seu teste gratuito começa na sua primeira reunião, não antes.",
    heading: "Seu teste ainda não começou",
    body: (trial: TrialFacts): readonly string[] => [
      `Você se cadastrou no Gistsmith, mas ainda não gravou nenhuma reunião. Tudo bem: seu teste gratuito (${trial.meetings} reuniões ou ${trial.days} dias) só começa na sua primeira reunião.`,
      "Na próxima chamada no Zoom, Teams ou Google Meet, ou numa reunião presencial, inicie a gravação no Gistsmith. A nota fica pronta quando a reunião terminar.",
      "Este é o único lembrete que enviamos sobre isso.",
    ],
    cta: "Gravar uma reunião",
  },
  trialEnding: {
    subject: "Seu teste do Gistsmith termina em breve",
    preheader: "O que acontece depois com suas reuniões e notas.",
    heading: "Seu teste termina em breve",
    oneMeetingLeft: "Você tem mais uma reunião de teste gratuita.",
    endsWithinDay: "Seu teste gratuito termina em menos de um dia.",
    nextFree: (free: FreePlanFacts): string =>
      `Depois disso, sua conta passa sozinha para o plano gratuito: ${free.notesPerMonth} notas com IA por mês para reuniões de até ${free.maxMeetingMinutes} minutos e ${free.asksPerMonth} respostas do Perguntar por mês.`,
    nextSubscribe: "Depois disso, uma assinatura mantém o Gistsmith transcrevendo suas reuniões e escrevendo as notas.",
    keep: "De qualquer forma, suas reuniões e notas continuam nos seus dispositivos.",
    cta: "Ver planos",
  },
  freePlan: {
    subject: "Você está no plano gratuito do Gistsmith",
    preheader: "O que o plano gratuito inclui todo mês.",
    heading: "Boas-vindas ao plano gratuito",
    intro: "Seu teste terminou e sua conta agora está no plano gratuito. Ele não expira.",
    items: (free: FreePlanFacts): readonly string[] => [
      `${free.notesPerMonth} notas com IA por mês, para reuniões de até ${free.maxMeetingMinutes} minutos`,
      `${free.asksPerMonth} respostas do Perguntar por mês`,
      "Transcrições feitas no seu dispositivo",
      "O Teclado Gistsmith no iPhone",
    ],
    outro: "Quando precisar de reuniões mais longas ou mais notas, Personal e Pro aumentam os limites.",
    cta: "Comparar planos",
  },
};
