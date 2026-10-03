import { registerWebModule, NativeModule } from 'expo';

class DirectSmsModule extends NativeModule<{}> {}

export default registerWebModule(DirectSmsModule, 'DirectSmsModule');
