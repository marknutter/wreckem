require 'wreckem/entity_manager'

# Coverage the original suite lacked, exercised against BOTH backends via
# for_each_backend (spec_helper.rb):
#
#   * intersects WITH a trailing where-hash: value match, value non-match,
#     :eid filter, and the ref-component value path -- the original suite only
#     ever called `A.intersects(B)` with no where-clause, so the whole filter
#     branch of load_components_from_classes was untested on either backend.
#   * intersects negation via the leading-'!' string form.
#   * enumeration distinctness: an entity holding several components of
#     different classes must count exactly once in #size and #to_a.
#
# Booleans are deliberately avoided (documented SQLite-vs-Ruby divergence); the
# components below are int / string / ref.

Xval  = Wreckem::Component.define_as_int      # int
Xkind = Wreckem::Component.define_as_string   # string
Xlink = Wreckem::Component.define_as_ref      # ref

describe "backend intersects + where-hash + distinctness" do
  for_each_backend do
    before { @em = Wreckem::EntityManager.new }
    after  { @em.destroy }

    # a: Xval=4 only        (no Xkind, so never in an Xval∩Xkind intersection)
    # b: Xval=5, Xkind=circle
    # c: Xval=7, Xkind=square
    def build_world
      @a = Wreckem::Entity.is! { |e| e.has Xval.new(4) }
      @b = Wreckem::Entity.is! do |e|
        e.has Xval.new(5)
        e.has Xkind.new("circle")
      end
      @c = Wreckem::Entity.is! do |e|
        e.has Xval.new(7)
        e.has Xkind.new("square")
      end
    end

    def pairs(*intersects_args)
      out = []
      Xval.intersects(*intersects_args) { |xval, xkind| out << [xval.value, xkind.value] }
      out.sort_by(&:first)
    end

    context "intersects with no where-hash (baseline)" do
      it "yields only the entities carrying both components" do
        build_world
        expect(pairs(Xkind)).to eq([[5, "circle"], [7, "square"]])
      end
    end

    context "intersects with a where-hash" do
      it "restricts to a matching int value" do
        build_world
        expect(pairs(Xkind, :Xval => { :value => 5 })).to eq([[5, "circle"]])
      end

      it "restricts to a matching string value" do
        build_world
        expect(pairs(Xkind, :Xkind => { :value => "square" })).to eq([[7, "square"]])
      end

      it "yields nothing when the value matches no entity" do
        build_world
        expect(pairs(Xkind, :Xval => { :value => 999 })).to eq([])
      end

      it "filters by :eid (string form -- the cross-backend contract)" do
        build_world
        expect(pairs(Xkind, :Xval => { :eid => @b.id.to_s })).to eq([[5, "circle"]])
      end

      it "filters by :eid down to a single entity even amid several matches" do
        build_world
        expect(pairs(Xkind, :Xval => { :eid => @c.id.to_s })).to eq([[7, "square"]])
      end

      it "matches on a ref component's value" do
        target = Wreckem::Entity.is! { |e| e.has Xkind.new("beacon") }
        linked = Wreckem::Entity.is! do |e|
          e.has Xval.new(3)
          e.has Xlink.new(target.id)
        end
        Wreckem::Entity.is! do |e|      # decoy: links elsewhere
          e.has Xval.new(8)
          e.has Xlink.new(999)
        end

        out = []
        Xval.intersects(Xlink, :Xlink => { :value => target.id }) do |xval, xlink|
          out << [xval.value, xlink.value]
        end

        expect(out).to eq([[3, target.id]])
        expect(linked).not_to be_nil
      end
    end

    context "intersects negation (leading '!' string)" do
      it "excludes the entity whose string value matches" do
        build_world
        expect(pairs(Xkind, :Xkind => { :value => "!circle" })).to eq([[7, "square"]])
      end

      it "yields everything in the intersection when nothing matches the excluded value" do
        build_world
        # No entity in the Xval∩Xkind set has kind 'triangle', so negating it
        # leaves both intersecting entities.
        expect(pairs(Xkind, :Xkind => { :value => "!triangle" })).to eq([[5, "circle"], [7, "square"]])
      end
    end

    context "enumeration distinctness" do
      it "counts an entity with several different component classes exactly once" do
        Wreckem::Entity.is! do |e|
          e.has Xval.new(1)
          e.has Xkind.new("hydra")
          e.has Xlink.new(0)
        end

        expect(@em.size).to eq(1)
        expect(@em.to_a.size).to eq(1)
      end

      it "does not double-count across a mixed store" do
        multi = Wreckem::Entity.is! do |e|
          e.has Xval.new(1)
          e.has Xkind.new("a")
          e.has Xlink.new(0)
        end
        single = Wreckem::Entity.is! { |e| e.has Xval.new(2) }

        expect(@em.size).to eq(2)
        expect(@em.to_a.map(&:id).sort).to eq([multi.id, single.id].sort)
        expect(@em.to_a.map(&:id).uniq.size).to eq(2)
      end
    end
  end
end
