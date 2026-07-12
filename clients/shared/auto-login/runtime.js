(() => {
  const alphanumericCharset = {
    78: '2', 357: 'F', 409: '7', 687: 'D', 747: 'M', 761: 'C', 806: 'r',
    821: 'Y', 1066: 'b', 1107: 'c', 1583: 'J', 1614: 'I', 1638: 'f',
    1769: 'v', 2041: 'i', 2089: 'l', 2203: 'B', 2525: 'E', 2663: 'u',
    2879: '9', 3072: 'k', 3466: 's', 3930: 'P', 3963: 'Z', 4050: 'n',
    4410: '1', 4488: 'G', 4617: 'm', 4666: 'K', 4730: 'z', 4771: 'A',
    4810: 'W', 5027: 'p', 5046: 'T', 5225: 'X', 5418: 'O', 5554: 'H',
    5726: 'd', 5734: 'V', 5806: '4', 5961: '6', 6185: 'j', 6216: 'N',
    6257: 'e', 6386: 'S', 6601: 'Q', 6612: 'y', 6672: 'L', 6736: 'x',
    6749: '0', 6939: 'o', 6977: '5', 6979: '8', 7136: 'w', 7198: 'a',
    7262: 'R', 7284: 'U', 7405: 'q', 7721: '3', 7723: 't', 8119: 'g',
    8196: 'h'
  };

  ort.env.wasm.numThreads = 1;
  ort.env.wasm.proxy = false;
  ort.env.wasm.wasmPaths = new URL('./vendor/', window.location.href).href;

  let sessionPromise;

  function loadSession() {
    if (!sessionPromise) {
      console.info('[local-automation] loading OCR model');
      sessionPromise = ort.InferenceSession.create('./common_old.onnx', {
        executionProviders: ['wasm'],
        graphOptimizationLevel: 'all'
      }).then((session) => {
        console.info('[local-automation] OCR model ready');
        return session;
      });
    }
    return sessionPromise;
  }

  function loadImage(dataUrl) {
    return new Promise((resolve, reject) => {
      const image = new Image();
      image.onload = () => resolve(image);
      image.onerror = () => reject(new Error('验证码图片无法读取'));
      image.src = dataUrl;
    });
  }

  async function recognize(dataUrl) {
    if (!String(dataUrl || '').startsWith('data:image/')) {
      throw new Error('验证码图片格式无效');
    }

    console.info('[local-automation] OCR request started');
    const [session, image] = await Promise.all([loadSession(), loadImage(dataUrl)]);
    const height = 64;
    const width = Math.max(32, Math.min(512, Math.round(image.naturalWidth * height / image.naturalHeight)));
    const canvas = document.createElement('canvas');
    canvas.width = width;
    canvas.height = height;
    const context = canvas.getContext('2d', { willReadFrequently: true });
    context.drawImage(image, 0, 0, width, height);
    const rgba = context.getImageData(0, 0, width, height).data;
    const input = new Float32Array(width * height);
    for (let pixel = 0; pixel < input.length; pixel += 1) {
      const offset = pixel * 4;
      input[pixel] = (
        rgba[offset] * 0.299
        + rgba[offset + 1] * 0.587
        + rgba[offset + 2] * 0.114
      ) / 255;
    }

    console.info('[local-automation] OCR inference started');
    const outputMap = await session.run({
      input1: new ort.Tensor('float32', input, [1, 1, height, width])
    });
    const output = outputMap[session.outputNames[0]];
    const dimensions = output.dims;
    const sequenceLength = dimensions[0] === 1 ? dimensions[1] : dimensions[0];
    const classCount = dimensions[dimensions.length - 1];
    const batchFirst = dimensions[0] === 1;
    let previous = -1;
    let text = '';

    for (let step = 0; step < sequenceLength; step += 1) {
      const base = batchFirst ? step * classCount : step * classCount;
      let bestIndex = 0;
      let bestScore = Number.NEGATIVE_INFINITY;
      for (let index = 0; index < classCount; index += 1) {
        const score = output.data[base + index];
        if (score > bestScore) {
          bestScore = score;
          bestIndex = index;
        }
      }
      if (bestIndex !== previous && bestIndex !== 0 && alphanumericCharset[bestIndex]) {
        text += alphanumericCharset[bestIndex];
      }
      previous = bestIndex;
    }
    const result = text.replace(/[^0-9A-Za-z]/g, '');
    console.info(`[local-automation] OCR inference completed (${result.length} chars)`);
    return result;
  }

  function decodeBase32(secret) {
    const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
    let raw = String(secret || '').trim();
    if (/^otpauth:\/\//i.test(raw)) {
      try {
        raw = new URL(raw).searchParams.get('secret') || '';
      } catch (_) {
        throw new Error('Google 密钥链接格式无效');
      }
    }
    const cleaned = raw.toUpperCase().replace(/[\s-]/g, '').replace(/=+$/, '');
    if (!cleaned) throw new Error('Google 密钥为空');
    if (!/^[A-Z2-7]+$/.test(cleaned)) throw new Error('Google 密钥格式无效');
    let bits = 0;
    let value = 0;
    const bytes = [];
    for (const character of cleaned) {
      const index = alphabet.indexOf(character);
      if (index < 0) throw new Error('Google 密钥格式无效');
      value = (value << 5) | index;
      bits += 5;
      if (bits >= 8) {
        bytes.push((value >>> (bits - 8)) & 0xff);
        bits -= 8;
      }
    }
    return new Uint8Array(bytes);
  }

  async function generateTotp(secret, timestamp = Date.now()) {
    const keyBytes = decodeBase32(secret);
    const counter = BigInt(Math.floor(Number(timestamp) / 30_000));
    const counterBytes = new Uint8Array(8);
    let remaining = counter;
    for (let index = 7; index >= 0; index -= 1) {
      counterBytes[index] = Number(remaining & 0xffn);
      remaining >>= 8n;
    }
    const key = await crypto.subtle.importKey(
      'raw',
      keyBytes,
      { name: 'HMAC', hash: 'SHA-1' },
      false,
      ['sign']
    );
    const digest = new Uint8Array(await crypto.subtle.sign('HMAC', key, counterBytes));
    const offset = digest[digest.length - 1] & 0x0f;
    const binary = (
      ((digest[offset] & 0x7f) << 24)
      | ((digest[offset + 1] & 0xff) << 16)
      | ((digest[offset + 2] & 0xff) << 8)
      | (digest[offset + 3] & 0xff)
    );
    return String(binary % 1_000_000).padStart(6, '0');
  }

  globalThis.localAutomationRuntime = {
    ready: async () => {
      await loadSession();
      return true;
    },
    recognize,
    generateTotp
  };
})();
