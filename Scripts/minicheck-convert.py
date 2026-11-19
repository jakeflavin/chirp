# For the summaries' sentence checker: lytang/MiniCheck-RoBERTa-Large ships only
# pytorch_model.bin; this writes the fp16 model.safetensors mlx-swift-lm loads. Then set config.json's id2label to
# {"0":"unsupported","1":"entailment"} and copy the tokenizer files beside it.
# Converts a PyTorch pytorch_model.bin (zip + pickle) to model.safetensors in float16, without torch.
# Reads tensors one at a time through numpy. Usage: python3 -I Scripts/minicheck-convert.py <in.bin> <out.safetensors>
import sys, zipfile, pickle, json, struct, collections
import numpy as np
src, dst = sys.argv[1], sys.argv[2]
zf = zipfile.ZipFile(src)
prefix = zf.namelist()[0].split('/')[0]
DT = {'FloatStorage': np.float32, 'HalfStorage': np.float16, 'LongStorage': np.int64, 'IntStorage': np.int32, 'BFloat16Storage': None}
class StorageType:
    def __init__(self, name): self.name = name
def rebuild(storage, offset, size, stride, *args):
    data, dtype = storage
    n = int(np.prod(size)) if len(size) else 1
    arr = np.frombuffer(data, dtype=dtype, count=n, offset=offset * np.dtype(dtype).itemsize)
    if len(size) and n:
        arr = np.lib.stride_tricks.as_strided(arr, shape=size, strides=[s * np.dtype(dtype).itemsize for s in stride])
    return np.array(arr).reshape(size)
class U(pickle.Unpickler):
    def find_class(self, mod, name):
        if mod == 'torch._utils' and name == '_rebuild_tensor_v2': return rebuild
        if mod == 'torch' and name.endswith('Storage'): return StorageType(name)
        if mod == 'collections' and name == 'OrderedDict': return collections.OrderedDict
        raise pickle.UnpicklingError(f'blocked {mod}.{name}')
    def persistent_load(self, pid):
        _, st, key, loc, numel = pid
        return (zf.read(f'{prefix}/data/{key}'), DT[st.name])
state = U(zf.open(f'{prefix}/data.pkl')).load()
header, chunks, offset = {}, [], 0
for k, v in state.items():
    a = v.astype(np.float16) if v.dtype == np.float32 else v
    b = a.tobytes()
    header[k] = {'dtype': {np.dtype(np.float16): 'F16', np.dtype(np.int64): 'I64', np.dtype(np.int32): 'I32'}[a.dtype], 'shape': list(a.shape), 'data_offsets': [offset, offset + len(b)]}
    chunks.append(b); offset += len(b)
header['__metadata__'] = {'format': 'pt'}
h = json.dumps(header).encode(); h += b' ' * ((8 - len(h) % 8) % 8)
with open(dst, 'wb') as f:
    f.write(struct.pack('<Q', len(h))); f.write(h)
    for b in chunks: f.write(b)
print(len(state), 'tensors,', offset // 1048576, 'MB;', sorted(state)[:3], sorted(state)[-3:])
