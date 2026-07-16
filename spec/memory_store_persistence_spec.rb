require 'wreckem/entity_manager'
require 'tmpdir'

# MemoryStore-only: SequelStore is durable for free (its #save is a no-op and
# the world lives in the db file), so a marshal/restore round-trip is a
# property of the in-memory backend alone.  MemoryStore#save marshals the world
# to a `db` file; MemoryStore.restore reads it back (falling back to a fresh
# empty store when the file is absent).
#
# Everything here runs inside a throwaway temp dir so the `db` file it writes
# can never clobber the repo's working directory.

SvName = Wreckem::Component.define_as_string
SvHp   = Wreckem::Component.define_as_int
SvTag  = Wreckem::Component.define   # content-less aspect

describe "Wreckem::MemoryStore save / restore round-trip" do
  around(:each) do |example|
    Dir.mktmpdir do |dir|
      Dir.chdir(dir) { example.run }
    end
  end

  it "persists a single-entity world to disk and restores it into a fresh manager" do
    em = Wreckem::EntityManager.new(Wreckem::MemoryStore.new)

    goblin = Wreckem::Entity.is! do |e|
      e.has SvName.new("goblin")
      e.has SvHp.new(9)
      e.is  SvTag
    end

    expect(em.size).to eq(1)
    expect(File.exist?("db")).to eq(false)

    em.save
    expect(File.exist?("db")).to eq(true)

    restored = Wreckem::MemoryStore.restore
    expect(restored).to be_a(Wreckem::MemoryStore)

    # A genuinely fresh manager over the restored store.
    em2 = Wreckem::EntityManager.new(restored)
    expect(em2.size).to eq(1)

    found = Wreckem::Entity.find(goblin.id)
    expect(found).not_to be_nil
    expect(found).to eq(goblin)
    expect(SvName.one(found).value).to eq("goblin")
    expect(SvHp.one(found).value).to eq(9)
    expect(found.is?(SvTag)).to eq(true)
  end

  it "reflects the value present at save time, not the original" do
    em = Wreckem::EntityManager.new(Wreckem::MemoryStore.new)
    entity = Wreckem::Entity.is! { |e| e.has SvHp.new(5) }

    SvHp.one(entity).update!(42)   # persist the new value into the store
    em.save

    em2 = Wreckem::EntityManager.new(Wreckem::MemoryStore.restore)
    expect(SvHp.one(Wreckem::Entity.find(entity.id)).value).to eq(42)
  end

  it "restore falls back to a fresh empty store when no db file exists" do
    expect(File.exist?("db")).to eq(false)

    restored = Wreckem::MemoryStore.restore
    expect(restored).to be_a(Wreckem::MemoryStore)

    em = Wreckem::EntityManager.new(restored)
    expect(em.size).to eq(0)
    expect(Wreckem::Entity.find(0)).to be_nil
  end

  # KNOWN BUG (reported, not fixed): MemoryStore#save + .restore corrupts a
  # world containing MORE THAN ONE entity.  After restore, reading the
  # components of any entity beyond the first raises
  #   NoMethodError: undefined method 'split' for an instance of Hash
  # from name_to_class (memory.rb:243) -- hydrate hands a Hash where a
  # component class-name string is expected.  A single-entity world (above)
  # restores fine, and multi-entity worlds work perfectly WITHOUT a
  # save/restore cycle, so the defect is specific to the marshal/restore path.
  # SequelStore is unaffected (durable storage, #save is a no-op).
  #
  # `pending` runs the example and expects it to fail: the suite stays green
  # while documenting the defect, and RSpec will flip this to a hard failure
  # the moment the bug is fixed, prompting removal of the pending marker.
  it "persists a MULTI-entity world and restores every entity" do
    pending("MemoryStore.restore corrupts multi-entity worlds (Hash reaches name_to_class) -- see test-run report")

    em = Wreckem::EntityManager.new(Wreckem::MemoryStore.new)

    goblin = Wreckem::Entity.is! { |e| e.has SvName.new("goblin"); e.has SvHp.new(9) }
    orc    = Wreckem::Entity.is! { |e| e.has SvName.new("orc");    e.has SvHp.new(14) }

    em.save
    em2 = Wreckem::EntityManager.new(Wreckem::MemoryStore.restore)

    expect(em2.size).to eq(2)
    expect(SvName.one(Wreckem::Entity.find(goblin.id)).value).to eq("goblin")
    expect(SvName.one(Wreckem::Entity.find(orc.id)).value).to eq("orc")
    expect(SvHp.one(Wreckem::Entity.find(orc.id)).value).to eq(14)
  end
end
