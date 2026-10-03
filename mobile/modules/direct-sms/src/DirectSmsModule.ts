import { NativeModule, requireNativeModule } from 'expo';

declare class DirectSmsModule extends NativeModule<{}> {}

export default requireNativeModule<DirectSmsModule>('DirectSms');
