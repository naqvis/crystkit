require "./spec_helper"
require "json-schema"
require "../../src/builder/config"
require "../../src/security/manifest"
describe "JSON Schema generation" do
  it "committed crystkit.schema.json matches generated output" do
    generated = CrystKit::Builder::Config.json_schema
    committed_path = Path[__DIR__].parent.parent / "schemas" / "crystkit.schema.json"
    committed = File.exists?(committed_path) ? JSON.parse(File.read(committed_path)) : nil
    if committed
      generated_props = JSON.parse(generated.to_json)
      generated_props["properties"].should eq(committed["properties"]),
        "schemas/crystkit.schema.json is out of date. Run: crystkit schema -o ./schemas"
    else
      fail "schemas/crystkit.schema.json not found. Run: crystkit schema -o ./schemas"
    end
  end
  it "committed capabilities.schema.json matches generated output" do
    generated = CrystKit::Security::Manifest.json_schema
    committed_path = Path[__DIR__].parent.parent / "schemas" / "capabilities.schema.json"
    committed = File.exists?(committed_path) ? JSON.parse(File.read(committed_path)) : nil
    if committed
      generated_props = JSON.parse(generated.to_json)
      generated_props["properties"].should eq(committed["properties"]),
        "schemas/capabilities.schema.json is out of date. Run: crystkit schema -o ./schemas"
    else
      fail "schemas/capabilities.schema.json not found. Run: crystkit schema -o ./schemas"
    end
  end
end
