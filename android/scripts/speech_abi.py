"""Compare JNI-visible declarations in JVM classes with the paired official APK's DEX.

Only standard-library parsing is used; nothing is executed. Instance fields,
constructors (including Kotlin masks), and native methods must match for every
API class shipped in the APK. Compose's synthetic static $stable is irrelevant.
"""
import io
import struct
import zipfile

PREFIX = "Lcom/k2fsa/sherpa/onnx/"


def class_declarations(blob):
    stream = io.BytesIO(blob)
    def read(fmt):
        return struct.unpack(">" + fmt, stream.read(struct.calcsize(">" + fmt)))
    if read("I")[0] != 0xCAFEBABE:
        raise ValueError("Invalid JVM class")
    read("HH")
    pool = [None] * read("H")[0]
    index = 1
    while index < len(pool):
        tag = read("B")[0]
        if tag == 1:
            pool[index] = stream.read(read("H")[0]).decode("utf-8", errors="replace")
        elif tag in (7, 8, 16, 19, 20):
            pool[index] = read("H")[0]
        elif tag in (3, 4, 9, 10, 11, 12, 17, 18):
            stream.read(4)
        elif tag in (5, 6):
            stream.read(8); index += 1
        elif tag == 15:
            stream.read(3)
        else:
            raise ValueError("Unsupported JVM constant " + str(tag))
        index += 1
    _, this, _ = read("HHH")
    name = "L" + pool[pool[this]] + ";"
    stream.read(2 * read("H")[0])
    def attributes():
        for _ in range(read("H")[0]):
            _, length = read("HI"); stream.seek(length, 1)
    fields, constructors, native = set(), set(), set()
    for _ in range(read("H")[0]):
        flags, field, descriptor = read("HHH")
        if not flags & 8:
            fields.add((pool[field], pool[descriptor]))
        attributes()
    for _ in range(read("H")[0]):
        flags, method, descriptor = read("HHH")
        if pool[method] == "<init>":
            constructors.add(pool[descriptor])
        if flags & 0x100:
            native.add((pool[method], pool[descriptor], bool(flags & 8)))
        attributes()
    return name, {"fields": fields, "constructors": constructors, "native": native}


def jar_declarations(blob):
    with zipfile.ZipFile(io.BytesIO(blob)) as archive:
        return dict(class_declarations(archive.read(name)) for name in archive.namelist()
                    if name.startswith(PREFIX[1:]) and name.endswith(".class"))


def dex_declarations(blob):
    if not blob.startswith(b"dex\n"):
        raise ValueError("Invalid DEX")
    def u32(offset): return struct.unpack_from("<I", blob, offset)[0]
    def uleb(offset):
        value, shift = 0, 0
        while True:
            byte = blob[offset]; offset += 1; value |= (byte & 127) << shift
            if byte < 128: return value, offset
            shift += 7
            if shift > 35: raise ValueError("Invalid DEX ULEB128")
    def table(header, width, decode):
        count, offset = struct.unpack_from("<II", blob, header)
        return [decode(offset + i * width) for i in range(count)]
    def string(offset):
        _, start = uleb(u32(offset))
        return blob[start:blob.index(0, start)].decode("utf-8", errors="replace")
    strings = table(56, 4, string)
    types = table(64, 4, lambda offset: strings[u32(offset)])
    def proto(offset):
        _, result, arguments = struct.unpack_from("<III", blob, offset)
        parameters = [] if not arguments else struct.unpack_from("<" + "H" * u32(arguments), blob, arguments + 4)
        return "(" + "".join(types[i] for i in parameters) + ")" + types[result]
    protos = table(72, 12, proto)
    fields = table(80, 8, lambda offset: struct.unpack_from("<HHI", blob, offset))
    methods = table(88, 8, lambda offset: struct.unpack_from("<HHI", blob, offset))
    classes = table(96, 32, lambda offset: struct.unpack_from("<IIIIIIII", blob, offset))
    result = {}
    for clazz in classes:
        name, data = types[clazz[0]], clazz[6]
        if not name.startswith(PREFIX) or "/" in name[len(PREFIX):] or not data:
            continue
        sizes = []
        for _ in range(4):
            count, data = uleb(data); sizes.append(count)
        entry = {"fields": set(), "constructors": set(), "native": set()}
        for group, count in enumerate(sizes):
            index = 0
            for _ in range(count):
                delta, data = uleb(data); index += delta
                flags, data = uleb(data)
                if group < 2:
                    if group == 1:
                        _, typ, field = fields[index]
                        entry["fields"].add((strings[field], types[typ]))
                else:
                    _, data = uleb(data)  # code offset
                    _, signature, method = methods[index]
                    if strings[method] == "<init>": entry["constructors"].add(protos[signature])
                    if flags & 0x100: entry["native"].add((strings[method], protos[signature], bool(flags & 8)))
        result[name] = entry
    return result


def apk_declarations(path):
    result = {}
    with zipfile.ZipFile(path) as archive:
        for name in archive.namelist():
            if name.startswith("classes") and name.endswith(".dex"):
                result.update(dex_declarations(archive.read(name)))
    return result


def check_api(classes, apk):
    expected, actual = apk_declarations(apk), jar_declarations(classes)
    differences = []
    for name, wanted in expected.items():
        # APK-specific demo classes are outside the API package and never enter this comparison.
        if name not in actual:
            differences.append(f"{name}: missing class")
            continue
        for part in ("fields", "constructors", "native"):
            if wanted[part] != actual[name][part]:
                differences.append(f"{name} {part}: missing={sorted(wanted[part] - actual[name][part])}, extra={sorted(actual[name][part] - wanted[part])}")
    if differences:
        raise ValueError("Sherpa JNI/API ABI mismatch:\n" + "\n".join(differences))
    return len(expected)
