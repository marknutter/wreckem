require 'wreckem/entity_manager'
require 'wreckem/component'

# Issue #3 -- EntityManager#size / #each must work on the SQL backend.
#
# EntityManager includes Enumerable and delegates #each and #size to
# @backend.entities.  The SQL backend (the DEFAULT backend) never implemented
# `entities`, so #size, #each, and every Enumerable method riding on #each
# raised NoMethodError.  These specs pin the enumeration contract against the
# default backend.

MobName   = Wreckem::Component.define_as_string
HitPoints = Wreckem::Component.define_as_int
Alive     = Wreckem::Component.define
Armed     = Wreckem::Component.define

describe Wreckem::EntityManager do
  # Run every example below against each storage backend; see spec_helper.rb.
  for_each_backend do
  before { @em = Wreckem::EntityManager.new }
  after { @em.destroy }

  # Build an entity with `name` plus `extras` additional components so that
  # component-count and entity-count are deliberately different numbers.
  def mob(name, *extras)
    Wreckem::Entity.is! do |e|
      e.has MobName.new(name)
      extras.each do |extra|
        extra.kind_of?(Class) ? e.is(extra) : e.has(extra)
      end
    end
  end

  context "an empty store" do
    it "should report a size of 0" do
      expect(@em.size).to eq(0)
    end

    it "should yield nothing from 'each'" do
      yielded = []
      @em.each { |e| yielded << e }
      expect(yielded).to be_empty
    end

    it "should produce an empty 'to_a'" do
      expect(@em.to_a).to eq([])
    end
  end

  context "#size" do
    it "should count entities without raising" do
      mob("goblin")
      mob("orc")

      expect { @em.size }.not_to raise_error
      expect(@em.size).to eq(2)
    end

    # An entity is not a row -- it is an id that components point at.  An
    # implementation that counts component rows instead of DISTINCT eids will
    # report 3 here.
    it "should count an entity with several components exactly once" do
      mob("hydra", HitPoints.new(30), Alive)

      expect(@em.size).to eq(1)
    end

    it "should count entities, not components, across a mixed store" do
      mob("a")                                  # 1 component
      mob("b", HitPoints.new(5))                # 2 components
      mob("c", HitPoints.new(9), Alive, Armed)  # 4 components

      # 7 component rows, 3 entities.
      expect(@em.size).to eq(3)
    end

    it "should reflect deletion of an entity" do
      doomed = mob("kobold", HitPoints.new(2), Alive)
      mob("survivor")

      expect(@em.size).to eq(2)

      doomed.delete

      expect(@em.size).to eq(1)
    end

    it "should return to 0 once every entity is deleted" do
      a = mob("a", HitPoints.new(1))
      b = mob("b", Alive)

      a.delete
      b.delete

      expect(@em.size).to eq(0)
    end
  end

  context "#each" do
    it "should yield every entity" do
      a = mob("a")
      b = mob("b")
      c = mob("c")

      yielded = []
      @em.each { |e| yielded << e }

      expect(yielded.map(&:id).sort).to eq([a.id, b.id, c.id].sort)
    end

    # The distinctness trap: 3 entities holding 1, 2 and 4 components each is
    # 7 component rows.  A non-distinct 'entities' yields 7 times.
    it "should yield each entity exactly once regardless of component count" do
      a = mob("a")
      b = mob("b", HitPoints.new(5))
      c = mob("c", HitPoints.new(9), Alive, Armed)

      ids = []
      @em.each { |e| ids << e.id }

      expect(ids.size).to eq(3)
      expect(ids.uniq.size).to eq(3)
      expect(ids.sort).to eq([a.id, b.id, c.id].sort)
    end

    it "should yield a single entity exactly once even when it has many components" do
      mob("hydra", HitPoints.new(30), Alive, Armed)

      ids = []
      @em.each { |e| ids << e.id }

      expect(ids.size).to eq(1)
    end

    it "should yield Wreckem::Entity instances, not ids or rows" do
      mob("goblin", HitPoints.new(3))

      yielded = []
      @em.each { |e| yielded << e }

      expect(yielded.size).to eq(1)
      expect(yielded.map(&:class)).to eq([Wreckem::Entity])
    end

    it "should yield entities whose components read back" do
      mob("goblin", HitPoints.new(3))

      entity = nil
      @em.each { |e| entity = e }

      expect(MobName.one(entity).value).to eq("goblin")
      expect(HitPoints.one(entity).value).to eq(3)
      expect(entity.is?(Alive)).to eq(false)
    end
  end

  context "Enumerable methods riding on #each" do
    it "should support 'to_a' with one element per entity" do
      a = mob("a", HitPoints.new(1), Alive)
      b = mob("b", HitPoints.new(2), Armed)

      entities = @em.to_a

      expect(entities.size).to eq(2)
      expect(entities.map(&:id).sort).to eq([a.id, b.id].sort)
    end

    it "should support 'count' without double counting multi-component entities" do
      mob("a")
      mob("b", HitPoints.new(2))
      mob("c", HitPoints.new(3), Alive, Armed)

      expect(@em.count).to eq(3)
    end

    it "should support 'map' over entities" do
      mob("goblin", HitPoints.new(3), Alive)
      mob("orc", HitPoints.new(7))

      names = @em.map { |e| MobName.one(e).value }

      expect(names.size).to eq(2)
      expect(names.sort).to eq(%w[goblin orc])
    end

    it "should support 'select' over entities" do
      mob("goblin", HitPoints.new(3), Alive)
      living = mob("orc", HitPoints.new(7), Alive, Armed)
      mob("corpse", HitPoints.new(0))

      armed = @em.select { |e| e.is?(Armed) }

      expect(armed.size).to eq(1)
      expect(armed.first.id).to eq(living.id)

      alive = @em.select { |e| e.is?(Alive) }
      expect(alive.map { |e| MobName.one(e).value }.sort).to eq(%w[goblin orc])
    end

    it "should support 'find' over entities" do
      mob("goblin", HitPoints.new(3))
      needle = mob("orc", HitPoints.new(7), Alive)

      found = @em.find { |e| MobName.one(e).value == "orc" }

      expect(found).not_to be_nil
      expect(found.id).to eq(needle.id)
    end
  end
  end
end
