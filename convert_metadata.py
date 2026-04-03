import json

def run():
    with open('/home/umignon/project/apitech/jitsi-videobridge/extracted-config/config-output/reachability-metadata.json', 'r') as f:
        data = json.load(f)

    reflect_config = []
    seen = set()
    primitives = {'boolean', 'byte', 'char', 'short', 'int', 'long', 'float', 'double', 'void'}

    for entry in data.get('reflection', []):
        name = entry.get('type')
        if not name or not isinstance(name, str):
            continue
        name = name.strip()
        if name in seen:
            continue
        seen.add(name)
        
        item = {"name": name}
        if name not in primitives and not name.endswith('[]') and not name.startswith('['):
            item.update({
                "allDeclaredConstructors": True,
                "allPublicConstructors": True,
                "allDeclaredMethods": True,
                "allPublicMethods": True,
                "allDeclaredFields": True,
                "allPublicFields": True
            })
        reflect_config.append(item)

    manual_classes = [
        "kotlin.reflect.jvm.internal.AbstractKType",
        "kotlin.reflect.jvm.internal.KTypeImpl",
        "kotlin.reflect.jvm.internal.KClassImpl",
        "kotlin.jvm.internal.TypeReference",
        "org.jivesoftware.smackx.xdata.packet.DataForm"
    ]

    for cls in manual_classes:
        if cls not in seen:
            reflect_config.append({
                "name": cls,
                "allDeclaredConstructors": True,
                "allPublicConstructors": True,
                "allDeclaredMethods": True,
                "allPublicMethods": True,
                "allDeclaredFields": True,
                "allPublicFields": True
            })

    with open('/home/umignon/project/apitech/jitsi-videobridge/config-full/reflect-config.json', 'w') as f:
        json.dump(reflect_config, f, indent=4)

if __name__ == "__main__":
    run()
