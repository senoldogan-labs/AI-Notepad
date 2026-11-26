import { Composition, Folder } from "remotion";
import "./brand";
import { Promo, SCENE_COMPONENTS } from "./Promo";
import { FPS, HEIGHT, SCENE_ORDER, sceneDuration, totalDuration, WIDTH } from "./timeline";
import { KB_FPS, KB_TOTAL, KeyboardAILandscape, KeyboardAILoop, KeyboardAIPortrait, KeyboardAISquare, LOOP_TOTAL as KB_LOOP_TOTAL } from "./keyboardai/KeyboardAI";
import "./voicetype/olive";
import { LiveTranslationPortrait, LiveTranslationSquare } from "./xclips/LiveTranslation";
import { NoBotPortrait, NoBotSquare } from "./xclips/NoBot";
import { X_FPS, X_TOTAL } from "./xclips/theme";
import { LOOP_TOTAL, VOICE_FPS, VOICE_TOTAL } from "./voicetype/script";
import { VoiceTypeBeforeAfter, VoiceTypeLoop } from "./voicetype/VoiceType";

export const RemotionRoot: React.FC = () => (
  <>
    <Folder name="Scenes">
      {SCENE_ORDER.map((scene) => (
        <Composition
          key={scene}
          id={`Scene-${scene}`}
          component={SCENE_COMPONENTS[scene]}
          width={WIDTH}
          height={HEIGHT}
          fps={FPS}
          durationInFrames={sceneDuration(scene)}
        />
      ))}
    </Folder>
    <Composition id="GistsmithPromo" component={Promo} width={WIDTH} height={HEIGHT} fps={FPS} durationInFrames={totalDuration()} />
    <Composition id="GistsmithPromoVertical" component={Promo} width={HEIGHT} height={WIDTH} fps={FPS} durationInFrames={totalDuration()} />
    <Folder name="VoiceType">
      <Composition id="VoiceTypeBeforeAfter" component={VoiceTypeBeforeAfter} width={1080} height={1920} fps={VOICE_FPS} durationInFrames={VOICE_TOTAL} />
      <Composition id="VoiceTypeBeforeAfterSquare" component={VoiceTypeBeforeAfter} width={1080} height={1080} fps={VOICE_FPS} durationInFrames={VOICE_TOTAL} />
      <Composition id="VoiceTypeLoop" component={VoiceTypeLoop} width={1080} height={1350} fps={VOICE_FPS} durationInFrames={LOOP_TOTAL} />
    </Folder>
    <Folder name="XClips">
      <Composition id="NoBotSquare" component={NoBotSquare} width={1080} height={1080} fps={X_FPS} durationInFrames={X_TOTAL} />
      <Composition id="NoBotPortrait" component={NoBotPortrait} width={1080} height={1920} fps={X_FPS} durationInFrames={X_TOTAL} />
      <Composition id="LiveTranslationSquare" component={LiveTranslationSquare} width={1080} height={1080} fps={X_FPS} durationInFrames={X_TOTAL} />
      <Composition id="LiveTranslationPortrait" component={LiveTranslationPortrait} width={1080} height={1920} fps={X_FPS} durationInFrames={X_TOTAL} />
    </Folder>
    <Folder name="KeyboardAI">
      <Composition id="KeyboardAI" component={KeyboardAIPortrait} width={1080} height={1920} fps={KB_FPS} durationInFrames={KB_TOTAL} />
      <Composition id="KeyboardAISquare" component={KeyboardAISquare} width={1080} height={1080} fps={KB_FPS} durationInFrames={KB_TOTAL} />
      <Composition id="KeyboardAILandscape" component={KeyboardAILandscape} width={1920} height={1080} fps={KB_FPS} durationInFrames={KB_TOTAL} />
      <Composition id="KeyboardAILoop" component={KeyboardAILoop} width={1080} height={1350} fps={KB_FPS} durationInFrames={KB_LOOP_TOTAL} />
    </Folder>
  </>
);
