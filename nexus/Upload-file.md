# Download and upload jar file

## (no Java needed): download any real JAR

This is the quickest for a _dummy_ artifact.

In your VM:

```bash
cd /tmp/c4e-demo

# download any small jar (example: junit)
wget https://repo1.maven.org/maven2/junit/junit/4.13.2/junit-4.13.2.jar -O c4e-demo-1.0.0.jar
```

Now you have a valid JAR at `/tmp/c4e-demo/c4e-demo-1.0.0.jar`.

Go to Nexus **Upload** screen and fill:

**Choose Assets/Components**

- **File\***: `c4e-demo-1.0.0.jar`
- **Classifier**: _(leave empty)_
- **Extension\***: `jar`

**Component coordinates**

- **Group ID\***: `com.bloomi5.c4e`
- **Artifact ID\***: `c4e-demo`
- **Version\***: `1.0.0`
- ✅ Check **Generate a POM file with these coordinates**
- **Packaging**: `jar` (if editable)

Click **Upload** – this time Nexus should accept it.

---
