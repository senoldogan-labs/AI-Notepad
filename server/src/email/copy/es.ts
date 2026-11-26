import type { EmailCopy, FreePlanFacts, TrialFacts } from "./types";

export const es: EmailCopy = {
  htmlLang: "es",
  footer: {
    lifecycleReason: "Recibes este correo porque pediste consejos y recordatorios de Gistsmith.",
    unsubscribe: "Darse de baja",
    inApp: "o desactívalo en Gistsmith › Ajustes › Cuenta.",
    confirmReason:
      "Alguien introdujo esta dirección en Gistsmith. Si no fuiste tú, ignora este correo: no se envía nada más si no se hace clic en el enlace, y borramos la dirección en 7 días.",
    notMe: "No fui yo",
    privacy: (address: string): string => `Preguntas sobre privacidad: ${address}`,
    privacyPolicy: "Política de privacidad",
    country: "Finlandia",
    reply: "¿Dudas? Responde a este correo.",
    linkFallback: "Si el botón no funciona, abre este enlace:",
  },
  confirm: {
    subject: "Confirma tu correo para Gistsmith",
    preheader: "Un clic para recibir consejos de Gistsmith y el aviso de tu prueba.",
    heading: "Confirma tu correo",
    body: [
      "Pediste a Gistsmith que te envíe algunos consejos y un recordatorio antes de que termine tu prueba gratuita.",
      "Confirma esta dirección y empezamos. No enviamos nada más y puedes dejarlo cuando quieras.",
    ],
    cta: "Confirmar mi correo",
    note: "El enlace es válido durante 7 días.",
  },
  welcome: {
    subject: "Tu primera reunión con Gistsmith",
    preheader: "Graba una reunión y recibe la nota al terminar.",
    heading: "Te damos la bienvenida a Gistsmith",
    body: [
      "La forma más rápida de ver lo que hace Gistsmith es una reunión real. Cuando empiece tu próxima llamada, haz clic en Iniciar grabación en Gistsmith en tu Mac, o abre Gistsmith en tu iPhone y toca Iniciar grabación.",
      "Al terminar la reunión, recibes la transcripción, una nota breve y las tareas.",
      "En el iPhone, el Teclado Gistsmith te permite escribir con la voz en cualquier app. Es gratis: actívalo en Gistsmith › Ajustes › Teclado.",
    ],
    cta: "Grabar una reunión",
  },
  activation: {
    subject: "¿Listo para tu primera reunión?",
    preheader: "Tu prueba gratuita empieza con tu primera reunión, no antes.",
    heading: "Tu prueba aún no ha empezado",
    body: (trial: TrialFacts): readonly string[] => [
      `Te registraste en Gistsmith pero aún no has grabado ninguna reunión. No pasa nada: tu prueba gratuita (${trial.meetings} reuniones o ${trial.days} días) solo empieza con tu primera reunión.`,
      "En tu próxima llamada de Zoom, Teams o Google Meet, o en una reunión presencial, inicia la grabación en Gistsmith. La nota estará lista al terminar.",
      "Es el único recordatorio que te enviamos sobre esto.",
    ],
    cta: "Grabar una reunión",
  },
  trialEnding: {
    subject: "Tu prueba de Gistsmith termina pronto",
    preheader: "Qué pasará después con tus reuniones y notas.",
    heading: "Tu prueba termina pronto",
    oneMeetingLeft: "Te queda una reunión de prueba gratuita.",
    endsWithinDay: "Tu prueba gratuita termina en menos de un día.",
    nextFree: (free: FreePlanFacts): string =>
      `Después, tu cuenta pasa sola al plan gratuito: ${free.notesPerMonth} notas con IA al mes para reuniones de hasta ${free.maxMeetingMinutes} minutos y ${free.asksPerMonth} respuestas de Preguntar al mes.`,
    nextSubscribe: "Después, una suscripción permite que Gistsmith siga transcribiendo tus reuniones y escribiendo las notas.",
    keep: "En cualquier caso, tus reuniones y notas se quedan en tus dispositivos.",
    cta: "Ver planes",
  },
  freePlan: {
    subject: "Estás en el plan gratuito de Gistsmith",
    preheader: "Lo que incluye el plan gratuito cada mes.",
    heading: "Bienvenido al plan gratuito",
    intro: "Tu prueba ha terminado y tu cuenta ya está en el plan gratuito. No caduca.",
    items: (free: FreePlanFacts): readonly string[] => [
      `${free.notesPerMonth} notas con IA al mes, para reuniones de hasta ${free.maxMeetingMinutes} minutos`,
      `${free.asksPerMonth} respuestas de Preguntar al mes`,
      "Transcripciones hechas en tu dispositivo",
      "El Teclado Gistsmith en el iPhone",
    ],
    outro: "Si necesitas reuniones más largas o más notas, Personal y Pro amplían los límites.",
    cta: "Comparar planes",
  },
};
