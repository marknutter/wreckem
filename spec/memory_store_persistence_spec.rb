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
SvRef  = Wreckem::Component.define_as_ref
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

  # Regression guard for the multi-entity save/restore corruption fixed in
  # 4c5b279.  Before the fix, a JRuby Marshal back-reference on the class-name
  # string shared across @rows/@ids_by_class corrupted every row past the
  # first, so restoring a world with >1 entity raised
  #   NoMethodError: undefined method 'split' for an instance of Hash
  # from name_to_class.  A single-entity round-trip (above) did NOT catch it,
  # so this test deliberately builds a MULTI-entity world with mixed component
  # types (int, string, ref, and a content-less aspect) and asserts every
  # entity survives the round-trip intact.  SequelStore is durable, so this is
  # a property of the in-memory backend alone -- but it runs identically here.
  it "persists a MULTI-entity world with mixed component types and restores every entity" do
    em = Wreckem::EntityManager.new(Wreckem::MemoryStore.new)

    goblin = Wreckem::Entity.is! do |e|
      e.has SvName.new("goblin")
      e.has SvHp.new(9)
      e.is  SvTag                     # aspect on the FIRST entity
    end
    orc = Wreckem::Entity.is! do |e|
      e.has SvName.new("orc")
      e.has SvHp.new(14)
    end
    rat = Wreckem::Entity.is! { |e| e.has SvName.new("rat") }   # single component

    link = Wreckem::Entity.is! do |e|
      e.has SvName.new("familiar")
      e.has SvRef.new(goblin.id)      # ref component pointing at the goblin
    end

    expect(em.size).to eq(4)

    em.save
    em2 = Wreckem::EntityManager.new(Wreckem::MemoryStore.restore)

    # Whole-world survival.
    expect(em2.size).to eq(4)
    expect(em2.to_a.map(&:id).sort).to eq([goblin.id, orc.id, rat.id, link.id].sort)

    # Every entity's components read back -- the entities *past the first* are
    # exactly what the corruption used to destroy.
    g = Wreckem::Entity.find(goblin.id)
    expect(SvName.one(g).value).to eq("goblin")
    expect(SvHp.one(g).value).to eq(9)
    expect(g.is?(SvTag)).to eq(true)

    o = Wreckem::Entity.find(orc.id)
    expect(SvName.one(o).value).to eq("orc")
    expect(SvHp.one(o).value).to eq(14)
    expect(o.is?(SvTag)).to eq(false)   # aspect must NOT bleed across entities

    r = Wreckem::Entity.find(rat.id)
    expect(SvName.one(r).value).to eq("rat")
    expect(r.components.size).to eq(1)

    l = Wreckem::Entity.find(link.id)
    expect(SvName.one(l).value).to eq("familiar")
    expect(SvRef.one(l).value).to eq(goblin.id)
    expect(SvRef.one(l).to_entity).to eq(goblin)

    # An id that never existed is still nil after a restore.
    expect(Wreckem::Entity.find(999_999)).to be_nil
  end
end
